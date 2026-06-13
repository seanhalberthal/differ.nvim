-- file-history panel (§8.4): a lightweight sidebar listing a file's commits,
-- newest first. it owns *which commit*; the View owns *how that commit's diff
-- renders*, so selecting/stepping a commit re-sources the single driven View, the
-- same separation the file panel uses (§8.6). source-agnostic by the same shape:
-- the local frontend feeds it commits and an on_select that builds the DiffModel.
-- commit-shaped, so it doesn't reuse panel/tree.lua (no dirs, sections, staging)

local set_wo = require("dipher.util.win").set_local

local ns = vim.api.nvim_create_namespace("dipher.history")
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

local HEADER_LINES = 2 -- file path + the "Help: g?" hint, before the commit rows

---@type dipher.History|nil -- the live history panel, for the runtime API
local current = nil

---@class dipher.History
---@field bufnr integer
---@field winid integer|nil
---@field origin_win integer|nil
---@field commits dipher.git.Commit[]
---@field index integer            -- 1-based selected commit
---@field on_select fun(commit: dipher.git.Commit)
---@field on_close fun()|nil
---@field path string              -- the file, for the header (display form)
---@field quarter_scroll boolean
---@field position string
---@field lines string[]
local History = {}
History.__index = History

---@class dipher.history.Opts
---@field commits dipher.git.Commit[]
---@field on_select fun(commit: dipher.git.Commit)
---@field on_close? fun()
---@field path string
---@field quarter_scroll? boolean
---@field position? "bottom"|"top"|"left"|"right"

-- build a history panel (buffer only; the window is created on :open, so it's
-- headless-constructible for tests)
---@param opts dipher.history.Opts
---@return dipher.History
function History.new(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "dipherhistory"
    vim.bo[bufnr].modifiable = false
    if not pcall(vim.api.nvim_buf_set_name, bufnr, "dipher://history") then
        pcall(vim.api.nvim_buf_set_name, bufnr, "dipher://history#" .. bufnr)
    end
    return setmetatable({
        bufnr = bufnr,
        commits = opts.commits,
        index = 1,
        on_select = opts.on_select,
        on_close = opts.on_close,
        path = opts.path,
        quarter_scroll = opts.quarter_scroll ~= false,
        position = opts.position or "bottom",
        lines = {},
    }, History)
end

-- 1-based buffer line of commit `i`
---@param i integer
---@return integer
local function commit_line(i)
    return HEADER_LINES + i
end

-- the commit index for a buffer line, or nil if the line is a header row
---@param lnum integer
---@return integer|nil
function History:_index_at(lnum)
    local i = lnum - HEADER_LINES
    return (i >= 1 and i <= #self.commits) and i or nil
end

-- a commit row: short sha, date, subject in fixed columns. returns the line plus
-- the byte offsets to highlight (sha + date; subject stays default)
---@param c dipher.git.Commit
---@return string line, integer date_col, integer date_end
local function commit_row(c)
    local sha = c.short
    local prefix = sha .. "  " -- two spaces between sha and date
    local date_col = #prefix
    local line = prefix .. c.date .. "  " .. c.subject
    return line, date_col, date_col + #c.date
end

-- repaint the buffer: a two-line header (file + help hint) then one row per commit
function History:render()
    local lines = { self.path, "Help: g?" }
    local rows = {} ---@type { date_col: integer, date_end: integer }[]
    for _, c in ipairs(self.commits) do
        local line, dc, de = commit_row(c)
        lines[#lines + 1] = line
        rows[#rows + 1] = { date_col = dc, date_end = de }
    end
    self.lines = lines

    vim.bo[self.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    vim.bo[self.bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
    local function paint(row, col, end_col, hl)
        vim.api.nvim_buf_set_extmark(self.bufnr, ns, row, col, { end_col = end_col, hl_group = hl })
    end
    paint(0, 0, #lines[1], "dipherPanelRoot")
    paint(1, 0, #lines[2], "dipherPanelHelp")
    for i, r in ipairs(rows) do
        local row = commit_line(i) - 1
        local sha = self.commits[i].short
        paint(row, 0, #sha, "dipherPanelDir") -- short sha
        paint(row, r.date_col, r.date_end, "dipherPanelHelp") -- date (muted)
    end
end

-- a non-history window to render diffs in: the origin window if still valid, else
-- any other window, else a fresh split carved off this panel (mirrors the panel)
---@return integer
function History:_ensure_origin()
    if
        self.origin_win
        and self.origin_win ~= self.winid
        and vim.api.nvim_win_is_valid(self.origin_win)
    then
        return self.origin_win
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= self.winid then
            self.origin_win = w
            return w
        end
    end
    vim.api.nvim_set_current_win(self.winid)
    vim.cmd("aboveleft split")
    self.origin_win = vim.api.nvim_get_current_win()
    return self.origin_win
end

-- render commit `i`'s diff in the main window. by default focus returns to the
-- panel; `keep_focus` leaves it in the diff window (in-view ]f/[f stepping)
---@param i integer
---@param keep_focus boolean|nil
function History:_open(i, keep_focus)
    self.index = i
    vim.api.nvim_set_current_win(self:_ensure_origin())
    self.on_select(self.commits[i])
    if not keep_focus and self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_set_current_win(self.winid)
    end
end

-- <CR>/o: render the commit under the cursor
---@param keep_focus boolean|nil
function History:select(keep_focus)
    local i = self:_index_at(vim.api.nvim_win_get_cursor(self.winid)[1])
    if i then
        self:_open(i, keep_focus)
    end
end

-- ]f / [f: step to the next/previous (older/newer) commit and render it. clamps at
-- the ends. `keep_focus` is threaded so in-view stepping stays in the diff window
---@param direction "next"|"prev"
---@param keep_focus boolean|nil
function History:step(direction, keep_focus)
    local i = self.index + (direction == "next" and 1 or -1)
    if i < 1 or i > #self.commits then
        return
    end
    if self:is_open() then
        vim.api.nvim_win_set_cursor(self.winid, { commit_line(i), 0 })
    end
    self:_open(i, keep_focus)
end

-- f / b: scroll the *diff view* a quarter page (named `scroll`, not `quarter_scroll`,
-- to avoid shadowing the boolean field, as in the file panel)
---@param direction "down"|"up"
function History:scroll(direction)
    local win = self.origin_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local n = math.max(1, math.floor(vim.api.nvim_win_get_height(win) / 4))
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! " .. n .. (direction == "down" and CTRL_D or CTRL_U))
    end)
end

-- g?: a floating keymap cheatsheet, dismissed with <Esc> / q / g?
function History:show_help()
    local lines = {
        " dipher file history",
        "",
        " <CR> / o   show commit",
        " ]f / [f    next / previous commit",
        " ]c / [c    next / previous hunk",
        " f / b      scroll diff down / up",
        " g?         this help",
    }
    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, #l)
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width + 1,
        height = #lines,
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " Dipher ",
    })
    local function close()
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    for _, lhs in ipairs({ "q", "<Esc>", "g?" }) do
        vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true })
    end
end

-- window appearance + buffer-local keymaps
function History:_setup_window()
    local win = self.winid
    set_wo(win, "number", false)
    set_wo(win, "relativenumber", false)
    set_wo(win, "signcolumn", "no")
    set_wo(win, "foldcolumn", "0")
    set_wo(win, "wrap", false)
    set_wo(win, "cursorline", true)
    if self.position == "left" or self.position == "right" then
        set_wo(win, "winfixwidth", true)
    else
        set_wo(win, "winfixheight", true)
    end

    local function map(lhs, fn, desc)
        vim.keymap.set(
            "n",
            lhs,
            fn,
            { buffer = self.bufnr, desc = "dipher history: " .. desc, nowait = true }
        )
    end
    map("<CR>", function()
        self:select()
    end, "show commit")
    map("o", function()
        self:select()
    end, "show commit")
    map("]f", function()
        self:step("next")
    end, "next commit")
    map("[f", function()
        self:step("prev")
    end, "previous commit")
    map("]c", function()
        require("dipher").goto_hunk("next")
    end, "next hunk")
    map("[c", function()
        require("dipher").goto_hunk("prev")
    end, "previous hunk")
    map("g?", function()
        self:show_help()
    end, "help")
    if self.quarter_scroll then
        map("f", function()
            self:scroll("down")
        end, "scroll down a quarter page")
        map("b", function()
            self:scroll("up")
        end, "scroll up a quarter page")
    end
end

-- create the split in the configured position, bind the buffer, set window opts
function History:_open_window()
    if self.position == "top" then
        vim.cmd("topleft 10split")
    elseif self.position == "left" then
        vim.cmd("topleft 40vsplit")
    elseif self.position == "right" then
        vim.cmd("botright 40vsplit")
    else -- bottom (default)
        vim.cmd("botright 10split")
    end
    self.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winid, self.bufnr)
    self:_setup_window()
end

-- open the panel, render, select the newest commit, and (by default) land the
-- cursor in the diff. returns self
---@param keep_focus boolean|nil  -- leave focus in the diff window (default true)
---@return dipher.History
function History:open(keep_focus)
    self.origin_win = vim.api.nvim_get_current_win()
    self:_open_window()
    self:render()
    vim.api.nvim_win_set_cursor(self.winid, { commit_line(1), 0 })
    current = self
    self:_open(1, keep_focus ~= false)
    return self
end

---@return boolean
function History:is_open()
    return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

-- close the panel window, wipe its buffer, and tear down the driven view via
-- on_close. ends the history session
function History:close()
    if self:is_open() then
        pcall(vim.api.nvim_win_close, self.winid, true)
    end
    self.winid = nil
    if vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
    if current == self then
        current = nil
    end
    if self.on_close then
        self.on_close()
    end
end

-- the live history panel, if one is open
---@return dipher.History|nil
function History.current()
    return current
end

return History
