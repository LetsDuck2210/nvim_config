local utils = require "utils"
local skim_flag_file = utils.get_flag_dir() .. "/skim_install"
local last_compilers_flag_file = utils.get_flag_dir() .. "/latex_last_compilers"

local function get_forwardsearch_config()
  local uname = utils.get_uname()
  if uname == utils.OS.macos then
    -- Only Skim is supported on macOS
    local skim_executable = "/Applications/Skim.app/Contents/SharedSupport/displayline"
    if vim.fn.executable(skim_executable) == 1 then
      return {
        executable = skim_executable,
        args = { "-r", "-g", "%l", "%p", "%f" },
      }
    end
  elseif uname == utils.OS.linux then
    local viewer = vim.fn.system("xdg-mime query default application/pdf"):gsub("\n", "")

    if string.find(viewer, "okular") then
      return {
        executable = "okular",
        args = { "--unique", "file:%p#src:%l%f" },
      }
    end

    print("Unsupported pdf viewer for synctex: " .. viewer)
  end
  return {}
end
local function texlab_forward_search()
  -- Get the current buffer and cursor position
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(),
    position = { line = vim.fn.line "." - 1, character = vim.fn.col "." - 1 },
  }
  -- Send the `texlab/forwardSearch` request
  vim.lsp.buf_request(0, "textDocument/forwardSearch", params, function(err)
    if err then vim.notify("Texlab forward search failed: " .. err.message, vim.log.levels.ERROR) end
  end)
end

--- check if skim is installed and ask to install if it isn't
local function check_skim()
  local skim_executable = "/Applications/Skim.app/Contents/SharedSupport/displayline"

  if vim.fn.executable(skim_executable) == 0 then
    if vim.fn.filereadable(skim_flag_file) ~= 1 then
      vim.fn.writefile({}, skim_flag_file)

      local should_install = vim.fn.confirm("Skim is not installed. Install now?", "&Yes\n&No", 1)
      if should_install ~= 1 then return end
      utils.ask_to_run("brew install skim", function(succeeded)
        if succeeded then
          vim.notify "Installation successful"
        else
          vim.notify("Installation failed", vim.log.levels.ERROR)
        end
      end)
    end
  end
end

--- Parse a dependency map in DOT format generated by texlab into a table
---@param dot string
---@return table<table<string,string>>
local function parse_dependencies_dot(dot)
  local files = {}
  -- Sample Line: v0000 [label="file:///path/to/file", shape=octagon];
  for name, file, shape in dot:gmatch '(%w+)%s*%[label="file://([^"]+)",%s*shape=(%w+)%];' do
    files[name] = { file = file, isRoot = (shape == "tripleoctagon") }
  end

  local map = {}
  for from, to in dot:gmatch "(%w+)%s*->%s*(%w+)[^;]*;" do
    table.insert(map, {
      from = files[from].file,
      to = files[to].file,
      isRoot = files[from].isRoot,
    })
  end
  return map
end

--- Find files including the current file given a dependency map (generated with parseDotDeps)
---@param dependencyMap table<table<string,string>>
---@param currentFile string
---@return table<string>
local function find_including_files(dependencyMap, currentFile)
  local files = { currentFile }
  for i, file in ipairs(files) do
    for _, mapping in ipairs(dependencyMap) do
      if file == mapping.to then
        local including = find_including_files(dependencyMap, mapping.from)
        if #including == 0 then break end

        if files[i] == file then files[i] = nil end
        for _, f in ipairs(including) do
          table.insert(files, f)
        end
        -- if mapping.isRoot then break end
      end
    end
  end
  return files
end
--- Set the current compiler of a specific client
---@param client vim.lsp.Client
---@param compiler string
---@param file string?
local function use_compiler(client, compiler, file)
  if file ~= nil then
    local lines = {}
    if vim.fn.filereadable(last_compilers_flag_file) == 1 then lines = vim.fn.readfile(last_compilers_flag_file) end

    local changed = false
    for i, line in ipairs(lines) do
      local prev = line
      if line:match(file) ~= nil then
        lines[i] = file .. "=" .. compiler
        if lines[i] == prev then return end
        changed = true
        break
      end
    end
    if changed then
      vim.fn.writefile(lines, last_compilers_flag_file)
    else
      vim.fn.writefile({ file .. "=" .. compiler }, last_compilers_flag_file, "a")
    end
  end
  if compiler == nil then
    vim.notify("Compiler cannot be nil", vim.log.levels.ERROR)
    return
  end

  if client.config.settings.texlab.build.command ~= compiler then
    print("compiler changed to " .. compiler)
    client.config.settings.texlab.build.command = compiler
    vim.cmd "LspRestart"
  end
end
--- Get the currently set compiler of a specific client
---@param client vim.lsp.Client
---@return string
local function get_compiler(client) return client.config.settings.texlab.build.command end

--- Find compilers specified at the beginning of the specified files
---@param files table<string>
---@param default_compiler string
---@return table<table<string,string>>, string
local function find_compilers(files, default_compiler)
  if #files == 0 then return {}, "" end

  local compilers = {}
  local global_compiler = default_compiler

  for _, file in ipairs(files) do
    local firstLines = vim.fn.readfile(file, "", 10)
    for _, line in ipairs(firstLines) do
      local patternBase = "^%% !TeX TXS%-program:§PROG§ = txs:///([%w_]+)$"
      local compiler = string.match(line, patternBase:gsub("§PROG§", "compile"))
      if compiler ~= nil then
        if #compilers == 0 then
          global_compiler = compiler
        else
          if compiler ~= global_compiler then global_compiler = "" end
        end

        table.insert(compilers, { compiler = compiler, file = file })
        break
      end
    end
  end

  return compilers, global_compiler
end

--- Read the last used compiler from a flag file
---@param file string
---@return string|nil
local function get_last_compiler(file)
  if vim.fn.filereadable(last_compilers_flag_file) ~= 1 then return nil end

  local lines = vim.fn.readfile(last_compilers_flag_file)
  for _, line in ipairs(lines) do
    local compiler = string.match(line, file .. "=(%w+)")
    if compiler ~= nil then return compiler end
  end
  return nil
end

--- Detect the compiler that should be used for the current buffer.
--- If the choice is ambiguous, the user will be asked to pick one
---@param client vim.lsp.Client lsp client
---@param bufnr integer buffer number
---@param check_last boolean check for the last used compiler before asking the user
local function detect_compiler(client, bufnr, check_last)
  vim.lsp.buf_request(
    bufnr,
    "workspace/executeCommand",
    { command = "texlab.showDependencyGraph", args = {} },
    function(err, result, _, _)
      if err then
        vim.notify("Texlab Error: " .. err)
        return
      end

      local current_file = vim.api.nvim_buf_get_name(bufnr)

      local dependencyMap = parse_dependencies_dot(result)
      local including_files = find_including_files(dependencyMap, current_file)

      local compilers, global_compiler = find_compilers(including_files, get_compiler(client))

      if global_compiler == "" or global_compiler == nil then
        if check_last then
          local last_compiler = get_last_compiler(current_file)
          local compiler_names = vim.tbl_map(function(val) return val.compiler end, compilers)
          if last_compiler ~= nil and vim.tbl_contains(compiler_names, last_compiler) then
            use_compiler(client, last_compiler, current_file)
            return
          end
        end

        -- ask the user which compiler to use if multiple different ones were detected
        vim.ui.select(compilers, {
          prompt = "Select compiler",
          format_item = function(item)
            local filename = item.file:match "^.*/(.+)$"
            return item.compiler .. " from " .. filename
          end,
        }, function(selected, _)
          if selected == nil then
            print("Using default compiler: " .. get_compiler(client))
            return
          end
          use_compiler(client, selected.compiler, current_file)
        end)
      else
        use_compiler(client, global_compiler, current_file)
      end
    end
  )
end
local function select_compiler_for_current_client()
  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients { name = "texlab", bufnr = bufnr }
  if #clients == 0 then return end

  detect_compiler(clients[1], bufnr, false)
end

return {
  setup = function(default_config)
    local config = vim.tbl_deep_extend("force", default_config, {
      on_attach = function(client, bufnr)
        local uname = utils.get_uname()
        if uname == utils.OS.macos then check_skim() end

        detect_compiler(client, bufnr, true)

        -- setup keybinds
        utils.set_lsp_keybinds(nil, bufnr)
        utils.set_keybinds({
          {
            "Show in viewer",
            "<leader>lj",
            utils.mapmode.normal,
            texlab_forward_search,
          },
          {
            "Detect/Select compiler",
            "<leader>lc",
            utils.mapmode.normal,
            select_compiler_for_current_client,
          },
        }, bufnr)
      end,
      settings = {
        texlab = {
          build = {
            args = { "-synctex=1", "%f" },
            command = "pdflatex",
            forwardSearchAfter = true,
            onSave = true,
          },
          forwardSearch = get_forwardsearch_config(),
        },
      },
    })

    require("lspconfig").texlab.setup(config)
  end,
}
