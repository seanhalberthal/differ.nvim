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
  -- the PR scene talks to the demo-only fixture sidecar (built by setup.sh), so the
  -- whole github flow is faked: no network, no gh, no token, fully reproducible
  sidecar_bin = root .. "/.demo/fake-sidecar/fake-sidecar",
})

-- plugin/differ.lua registers :Differ once the prepended runtimepath is sourced;
-- register here too as a guard in case plugin sourcing order varies
if not vim.g.loaded_differ then
  require("differ.command").register("Differ", "differ diff viewer")
  vim.g.loaded_differ = true
end

-- the launchers from the README starter. the d* ones are local-only; the p* ones drive
-- the PR frontend, which here points at the fixture sidecar (sidecar_bin above)
local map = vim.keymap.set
map("n", "<leader>do", "<cmd>Differ<CR>", { desc = "Diff: open" })
map("n", "<leader>dc", "<cmd>Differ close<CR>", { desc = "Diff: close" })
map("n", "<leader>dt", "<cmd>Differ base<CR>", { desc = "Diff: branch total" })
map("n", "<leader>de", "<cmd>Differ gofile<CR>", { desc = "Diff: open real file" })
map("n", "<leader>dh", "<cmd>Differ log<CR>", { desc = "Diff: file history" })
map("n", "<leader>dl", "<cmd>Differ layout<CR>", { desc = "Diff: toggle layout" })
map("n", "<leader>pl", "<cmd>Differ pr list<CR>", { desc = "PR: list" })
map("n", "<leader>pr", "<cmd>Differ pr review<CR>", { desc = "PR: review start" })
map("n", "<leader>pm", "<cmd>Differ pr review submit<CR>", { desc = "PR: review submit" })
map("n", "<leader>pk", "<cmd>Differ pr checks<CR>", { desc = "PR: checks" })

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
    -- a float belongs to the tabpage it was opened on; a `:Differ`/`tabnew` switch
    -- leaves it valid but invisible on the new tab, so `nvim_win_is_valid` alone
    -- doesn't catch staleness here -- check the float is still on the current tab too,
    -- else later keys (e.g. right after `do`) update a hidden window and never render
    if win and (not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()) then
      pcall(vim.api.nvim_win_close, win, true)
      win = nil
    end
    if win then
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

-- a tidy floating picker for the recording. the builtin vim.ui.select renders in the
-- cmdline (cramped, and the keycast float sits over it), which reads as broken on a
-- gif. this draws a centred rounded window the PR list + the submit-review event picker
-- both use; number keys pick directly (the tape types the item number), <CR> picks the
-- cursor line, q/<Esc> cancel
vim.ui.select = function(items, opts, on_choice)
  opts = opts or {}
  local fmt = opts.format_item or tostring
  local lines, width = {}, 0
  for i, item in ipairs(items) do
    lines[i] = ("  %d  %s  "):format(i, fmt(item))
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end
  local title = " " .. (opts.prompt or "Select") .. " "
  width = math.max(width, vim.fn.strdisplaywidth(title))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhl = "Normal:DemoKeycast,FloatBorder:DemoKeycastBorder,CursorLine:Visual"

  local done = false
  local function choose(idx)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    on_choice(idx and items[idx] or nil, idx)
  end
  for i = 1, #items do
    vim.keymap.set("n", tostring(i), function()
      choose(i)
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "<CR>", function()
    choose(vim.api.nvim_win_get_cursor(win)[1])
  end, { buffer = buf, nowait = true })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      choose(nil)
    end, { buffer = buf, nowait = true })
  end
end
