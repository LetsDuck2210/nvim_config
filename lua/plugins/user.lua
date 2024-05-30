return {
  {
    "williamboman/mason.nvim",
    config = function()
      require("mason").setup()
    end
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = {
      'williamboman/mason.nvim',
    },
    config = function()
      require("mason-lspconfig").setup({
        ensure_installed = {
          'arduino_language_server',
          'clangd',
          'rust_analyzer',
          'taplo',
          'tsserver',
        }
      })
    end
  },
  {
    "neovim/nvim-lspconfig",
    config = function()
      local lspconfig = require("lspconfig");
      local mason_lspconfig = require("mason-lspconfig")

      function set_keybinds(client, bufnr)
        local opts = { noremap = true, silent = true }

        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>ld', '<Cmd>lua vim.lsp.buf.definition()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lD', '<Cmd>lua vim.lsp.buf.declaration()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lR', '<Cmd>lua vim.lsp.buf.references()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>li', '<Cmd>lua vim.lsp.buf.implementation()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lh', '<Cmd>lua vim.lsp.buf.hover()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lH', '<Cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lwa', '<Cmd>lua vim.lsp.buf.add_workspace_folder()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lwr', '<Cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lwl', '<Cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>D', '<Cmd>lua vim.lsp.buf.type_definition()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lr', '<Cmd>lua vim.lsp.buf.rename()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>la', '<Cmd>lua vim.lsp.buf.code_action()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lef', '<Cmd>lua vim.diagnostic.open_float()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>lep', '<Cmd>lua vim.diagnostic.goto_prev()<CR>', opts)
        vim.api.nvim_buf_set_keymap(bufnr, 'n', '<leader>len', '<Cmd>lua vim.diagnostic.goto_next()<CR>', opts)
      end

      local default_config = {
        on_attach = set_keybinds,
      }
      local initialized = {}
      

      lspconfig.arduino_language_server.setup(vim.tbl_deep_extend("force", default_config, {
        on_new_config = function(config, _)
          config.capabilities.textDocument.semanticTokens = vim.NIL
          config.capabilities.workspace.semanticTokens = vim.NIL
          
          config.settings = {
            clangd = {
              arguments = {
                "--compile-commands-dir=" .. root_dir,
                "--log=verbose",
                "-Wno-unknown-attributes" -- Disable warnings for unknown attributes if necessary
              }
            }
          }
        end,
        root_dir = lspconfig.util.root_pattern("sketch.yaml", "*.ino", "*.pde"),
        filetypes = {"arduino", "cpp", "c", "ino", "pde", "h"},
        on_attach = set_keybinds,
      }))
      initialized["arduino_language_server"] = true

      lspconfig.clangd.setup(vim.tbl_deep_extend("force", default_config, {
        on_attach = function(client, bufnr)
          set_keybinds(client, bufnr)
          
          local arduino_files = vim.fn.glob("*.ino")
          if arduino_files ~= "" then
            client.stop()
          end
        end
      }))
      initialized["clangd"] = true
      
      mason_lspconfig.setup_handlers({
        function(server_name)
         -- if not lspconfig[server_name] then
          if not initialized[server_name]then
            lspconfig[server_name].setup(default_config)
          end
        end
      })
    end
  }
}
