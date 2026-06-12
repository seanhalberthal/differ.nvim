-- Minimal init for headless-nvim tests; puts the plugin on the runtimepath
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
