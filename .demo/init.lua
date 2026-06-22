-- minimal nvim config for the vhs demo: loads differ from the repo root and nothing
-- else, so the recording is the plugin, not a personal setup. mirrors the <leader>d*
-- launchers from the README's "Launchers" starter so the demo drives the real keys.
--
--   nvim -u .demo/init.lua <file>

local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p:h"), ":h")
vim.opt.runtimepath:prepend(root)

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- a clean, distraction-free frame for recording
vim.o.number = true
vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showcmd = false
vim.o.signcolumn = "yes"
vim.o.swapfile = false
vim.cmd.colorscheme("habamax") -- built-in, no plugin dependency

-- recolour the winbar: the panel's progress meter is a solid bar drawn in the winbar
-- foreground, which habamax renders near-white. tint it a muted green to match the
-- diff's add accent so it reads as a subtle meter, not a stark white block
vim.api.nvim_set_hl(0, "WinBar", { fg = "#a6cc7a", bg = "#2c2d27" })
vim.api.nvim_set_hl(0, "WinBarNC", { fg = "#7d9a52", bg = "#232420" })

require("differ").setup({
  command_alias = "D",
  context = 3, -- tighter context so the uncommitted edits read as separate hunks
})

-- plugin/differ.lua registers :Differ once the prepended runtimepath is sourced;
-- register here too as a guard in case plugin sourcing order varies
if not vim.g.loaded_differ then
  require("differ.command").register("Differ", "differ diff viewer")
  vim.g.loaded_differ = true
end

-- the local-diff launchers from the README starter (the PR ones need the sidecar)
local map = vim.keymap.set
map("n", "<leader>do", "<cmd>Differ<CR>", { desc = "Diff: open" })
map("n", "<leader>dc", "<cmd>Differ close<CR>", { desc = "Diff: close" })
map("n", "<leader>dt", "<cmd>Differ base<CR>", { desc = "Diff: branch total" })
map("n", "<leader>de", "<cmd>Differ gofile<CR>", { desc = "Diff: open real file" })
map("n", "<leader>dh", "<cmd>Differ log<CR>", { desc = "Diff: file history" })
map("n", "<leader>dl", "<cmd>Differ layout<CR>", { desc = "Diff: toggle layout" })

-- on-screen keycast: render the keys being driven in a small floating HUD (bottom
-- right) so the recording reads as "pressed X -> Y happened". dependency-free, via
-- vim.on_key. typed ex-commands narrate via the command line, so the HUD stays quiet
-- in cmdline mode. to move it, change the anchor/row/col in `render` below
do
  local uv = vim.uv or vim.loop
  local ns = vim.api.nvim_create_namespace("differ_demo_keycast")
  local buf = vim.api.nvim_create_buf(false, true)
  local win
  local text = ""
  local timer = uv.new_timer()

  vim.api.nvim_set_hl(0, "DemoKeycast", { fg = "#e6e6dc", bg = "#33342c", bold = true })
  vim.api.nvim_set_hl(0, "DemoKeycastBorder", { fg = "#7d9a52", bg = "#33342c" })

  local function hide()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    win = nil
  end

  local function render()
    if text == "" then
      return hide()
    end
    local label = " " .. text .. " "
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { label })
    local cfg = {
      relative = "editor",
      anchor = "SE",
      row = vim.o.lines - 2,
      col = vim.o.columns - 2,
      width = vim.fn.strdisplaywidth(label),
      height = 1,
      style = "minimal",
      border = "rounded",
      focusable = false,
      noautocmd = true,
      zindex = 300,
    }
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, cfg)
    else
      win = vim.api.nvim_open_win(buf, false, cfg)
      vim.wo[win].winhl = "Normal:DemoKeycast,FloatBorder:DemoKeycastBorder"
    end
  end

  vim.on_key(function(_, typed)
    local k = (typed and typed ~= "") and typed or nil
    if not k then
      return
    end
    vim.schedule(function()
      if vim.api.nvim_get_mode().mode:sub(1, 1) == "c" then
        return -- in the command line: the cmdline itself narrates
      end
      local pretty = vim.fn.keytrans(k)
      if pretty == "" or pretty == ":" or pretty == "<CR>" or pretty:find("Mouse") or pretty:find("ScrollWheel") then
        return -- <CR> only executes commands; not worth showing
      end
      text = (#text > 24 and "" or text) .. pretty
      render()
      timer:stop()
      timer:start(2800, 0, vim.schedule_wrap(function()
        text = ""
        render()
      end))
    end)
  end, ns)
end
