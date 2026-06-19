-- history panel: a sidebar listing commits, newest first. it owns *which
-- commit/file*; the View owns *how the diff renders*, so a selection re-sources the
-- single driven View (the separation the file panel uses). two modes:
--   file  — single-file history: each commit is one diff (commit vs its parent)
--   range — branch-range history: commits expand to their files (lazy); a file is
--           one diff. ]f/[f walk files across commits
-- commit-shaped, so it doesn't reuse panel/tree.lua; it keeps its own per-line meta

local set_wo = require("differ.util.win").set_local
local date_util = require("differ.util.date")
local bind = require("differ.util.keymap").bind

local ns = vim.api.nvim_create_namespace("differ.history")
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

local HEADER_LINES = 2 -- path/range + the "Help: g?" hint, before the commit rows
local AUTHOR_MAX = 18 -- cap the author column so a long name can't shove subjects off-screen

-- file-row status letter colours (mirrors the file panel's palette)
---@type table<string, string>
local STATUS_HL = {
    A = "differPanelAdd",
    M = "differPanelModify",
    D = "differPanelDelete",
    R = "differPanelRename",
    C = "differPanelRename",
    T = "differPanelModify",
}

---@type differ.History|nil -- the live history panel, for the runtime API
local current = nil

---@class differ.history.Meta
---@field kind "commit"|"file"
---@field ci integer            -- commit index
---@field fi integer|nil        -- file index within the commit (file rows)
---@field entry differ.FileEntry|nil

---@class differ.History
---@field bufnr integer
---@field winid integer|nil
---@field origin_win integer|nil
---@field return_tab integer|nil
---@field commits differ.git.Commit[]
---@field mode "file"|"range"
---@field index integer            -- selected commit
---@field file_index integer|nil   -- selected file within the commit (range mode)
---@field expanded table<string, boolean> -- per-sha fold state (range mode)
---@field files table<string, differ.FileEntry[]> -- per-sha lazy file cache (range)
---@field on_select fun(commit: differ.git.Commit)|nil   -- file mode
---@field expand fun(commit: differ.git.Commit): differ.FileEntry[]|nil -- range mode
---@field on_file fun(commit: differ.git.Commit, entry: differ.FileEntry)|nil -- range mode
---@field on_close fun()|nil
---@field path string              -- file path (file mode) or range (range mode), for the header
---@field keymaps table<string, string|string[]|false>
---@field relative_dates boolean
---@field position string
---@field lines string[]
---@field meta (differ.history.Meta|false)[]
local History = {}
History.__index = History

---@class differ.history.Opts
---@field commits differ.git.Commit[]
---@field mode? "file"|"range"
---@field on_select? fun(commit: differ.git.Commit)
---@field expand? fun(commit: differ.git.Commit): differ.FileEntry[]
---@field on_file? fun(commit: differ.git.Commit, entry: differ.FileEntry)
---@field on_close? fun()
---@field path string
---@field keymaps? table<string, string|string[]|false> -- resolved history action -> lhs
---@field relative_dates? boolean
---@field position? "bottom"|"top"|"left"|"right"

-- build a history panel (buffer only; the window is created on :open, so it's
-- headless-constructible for tests)
---@param opts differ.history.Opts
---@return differ.History
function History.new(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "differhistory"
    vim.bo[bufnr].modifiable = false
    if not pcall(vim.api.nvim_buf_set_name, bufnr, "differ://history") then
        pcall(vim.api.nvim_buf_set_name, bufnr, "differ://history#" .. bufnr)
    end
    return setmetatable({
        bufnr = bufnr,
        commits = opts.commits,
        mode = opts.mode or "file",
        index = 1,
        file_index = nil,
        expanded = {},
        files = {},
        on_select = opts.on_select,
        expand = opts.expand,
        on_file = opts.on_file,
        on_close = opts.on_close,
        path = opts.path,
        keymaps = vim.tbl_extend(
            "force",
            require("differ.config").defaults.keymaps,
            opts.keymaps or {}
        ),
        relative_dates = opts.relative_dates or false,
        position = opts.position or "bottom",
        lines = {},
        meta = {},
    }, History)
end

-- 1-based buffer line of commit `i` in file mode (rows are contiguous from line 3)
---@param i integer
---@return integer
local function commit_line(i)
    return HEADER_LINES + i
end

-- truncate to `w` bytes, marking the cut with an ellipsis
---@param s string
---@param w integer
---@return string
local function truncate(s, w)
    if #s <= w then
        return s
    end
    return s:sub(1, w - 1) .. "…"
end

-- shift highlight span columns by `off` bytes (after prefixing a row), in place
---@param spans { [1]: integer, [2]: integer, [3]: string }[]
---@param off integer
---@return { [1]: integer, [2]: integer, [3]: string }[]
local function shift(spans, off)
    for _, s in ipairs(spans) do
        s[1], s[2] = s[1] + off, s[2] + off
    end
    return spans
end

---@class differ.history.CommitCell
---@field sha string
---@field date string
---@field author string
---@field add integer
---@field del integer
---@field subject string
---@field refs string|nil

-- assemble a commit row from its cells, left-aligned and padded to the shared
-- column widths. returns the body plus highlight spans ({ col, end_col, hl }); the
-- count cell colours its +N and -M apart, and refs (range mode) trail the subject
---@param cells differ.history.CommitCell
---@param w { sha: integer, date: integer, count: integer, author: integer }
---@return string body, { [1]: integer, [2]: integer, [3]: string }[] spans
local function build_commit(cells, w)
    local parts, spans, col = {}, {}, 0
    local function emit(text)
        parts[#parts + 1] = text
        col = col + #text
    end
    local function cell(text, width, hl)
        local start = col
        emit(text)
        spans[#spans + 1] = { start, col, hl }
        if #text < width then
            emit(string.rep(" ", width - #text))
        end
        emit("  ")
    end
    cell(cells.sha, w.sha, "differPanelDir")
    cell(cells.date, w.date, "differPanelHelp")
    local add, del = "+" .. cells.add, "-" .. cells.del
    local cs = col
    local astart = col
    emit(add)
    spans[#spans + 1] = { astart, col, "differPanelCountAdd" }
    emit(" ")
    local dstart = col
    emit(del)
    spans[#spans + 1] = { dstart, col, "differPanelCountDelete" }
    if col - cs < w.count then
        emit(string.rep(" ", w.count - (col - cs)))
    end
    emit("  ")
    cell(cells.author, w.author, "differHistoryAuthor")
    emit(cells.subject) -- subject takes the rest, default colour
    if cells.refs then
        emit("  ")
        local rstart = col
        emit(cells.refs)
        spans[#spans + 1] = { rstart, col, "differHistoryRef" }
    end
    return table.concat(parts), spans
end

-- assemble a nested file row (range mode): "<status> <path>  +N -M"
---@param entry differ.FileEntry
---@return string body, { [1]: integer, [2]: integer, [3]: string }[] spans
local function build_file(entry)
    local parts, spans, col = {}, {}, 0
    local function emit(text)
        parts[#parts + 1] = text
        col = col + #text
    end
    spans[#spans + 1] = { col, col + #entry.status, STATUS_HL[entry.status] or "differPanelModify" }
    emit(entry.status)
    emit(" ")
    emit(entry.path)
    emit("  ")
    local add = "+" .. entry.additions
    spans[#spans + 1] = { col, col + #add, "differPanelCountAdd" }
    emit(add)
    emit(" ")
    local del = "-" .. entry.deletions
    spans[#spans + 1] = { col, col + #del, "differPanelCountDelete" }
    emit(del)
    return table.concat(parts), spans
end

---@param ci integer
---@return boolean
function History:_is_expanded(ci)
    return self.expanded[self.commits[ci].sha] == true
end

---@param ci integer
---@param v boolean
function History:_set_expanded(ci, v)
    self.expanded[self.commits[ci].sha] = v or nil
end

-- the (lazily loaded, cached) file list for commit `ci` (range mode)
---@param ci integer
---@return differ.FileEntry[]
function History:_files(ci)
    local sha = self.commits[ci].sha
    if not self.files[sha] then
        self.files[sha] = (self.expand and self.expand(self.commits[ci])) or {}
    end
    return self.files[sha]
end

-- repaint the buffer and rebuild the line meta: a two-line header then one row per
-- commit (sha · date · +N/-M · author · subject), with range mode adding fold
-- arrows, optional ref tags, and the expanded commits' files indented beneath
function History:render()
    local cells, w = {}, { sha = 0, date = 0, count = 0, author = 0 }
    for _, c in ipairs(self.commits) do
        local cell = {
            sha = c.short,
            date = date_util.format(c.epoch, { relative = self.relative_dates }),
            author = truncate(c.author, AUTHOR_MAX),
            add = c.additions,
            del = c.deletions,
            subject = c.subject,
            refs = (self.mode == "range" and c.refs ~= "") and c.refs or nil,
        }
        cells[#cells + 1] = cell
        w.sha = math.max(w.sha, #cell.sha)
        w.date = math.max(w.date, #cell.date)
        w.count = math.max(w.count, #("+" .. cell.add .. " -" .. cell.del))
        w.author = math.max(w.author, #cell.author)
    end

    local lines, meta, spans_by_line = { self.path, "Help: g?" }, { false, false }, {}
    local function push(line, m, spans)
        lines[#lines + 1] = line
        meta[#meta + 1] = m
        spans_by_line[#lines] = spans
    end
    for ci, cell in ipairs(cells) do
        if self.mode == "range" then
            local body, spans = build_commit(cell, w)
            local prefix = (self:_is_expanded(ci) and "▾" or "▸") .. " "
            shift(spans, #prefix)
            table.insert(spans, 1, { 0, #prefix - 1, "differPanelHelp" }) -- the fold arrow
            push(prefix .. body, { kind = "commit", ci = ci }, spans)
            if self:_is_expanded(ci) then
                for fi, entry in ipairs(self:_files(ci)) do
                    local fbody, fspans = build_file(entry)
                    shift(fspans, 4)
                    push(
                        "    " .. fbody,
                        { kind = "file", ci = ci, fi = fi, entry = entry },
                        fspans
                    )
                end
            end
        else
            local body, spans = build_commit(cell, w)
            push(body, { kind = "commit", ci = ci }, spans)
        end
    end
    self.lines, self.meta = lines, meta

    vim.bo[self.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    vim.bo[self.bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
    local function paint(row, col, end_col, hl)
        vim.api.nvim_buf_set_extmark(self.bufnr, ns, row, col, { end_col = end_col, hl_group = hl })
    end
    paint(0, 0, #lines[1], "differPanelRoot")
    paint(1, 0, #lines[2], "differPanelHelp")
    for lnum = HEADER_LINES + 1, #lines do
        for _, s in ipairs(spans_by_line[lnum] or {}) do
            paint(lnum - 1, s[1], s[2], s[3])
        end
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

-- move the panel cursor to `lnum` (clamped/guarded), without changing focus
---@param lnum integer|nil
function History:_move_cursor(lnum)
    if lnum and self:is_open() then
        pcall(vim.api.nvim_win_set_cursor, self.winid, { lnum, 0 })
    end
end

-- the meta record under the cursor, or nil on a header row
---@return differ.history.Meta|nil
function History:_cursor_meta()
    local m = self.winid and self.meta[vim.api.nvim_win_get_cursor(self.winid)[1]]
    return m or nil
end

-- buffer line of a commit / file row, found via the meta (range rows aren't contiguous)
---@param ci integer
---@return integer|nil
function History:_commit_line(ci)
    for i, m in ipairs(self.meta) do
        if m and m.kind == "commit" and m.ci == ci then
            return i
        end
    end
end

---@param ci integer
---@param fi integer
---@return integer|nil
function History:_file_line(ci, fi)
    for i, m in ipairs(self.meta) do
        if m and m.kind == "file" and m.ci == ci and m.fi == fi then
            return i
        end
    end
end

-- file mode: render commit `i`'s diff in the main window. by default focus returns
-- to the panel; `keep_focus` leaves it in the diff window (in-view ]f/[f stepping)
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

-- range mode: render the `fi`-th file of commit `ci` (expanding the commit first so
-- the row is visible), parking the panel cursor on it. `keep_focus` keeps focus in
-- the diff window
---@param ci integer
---@param fi integer
---@param keep_focus boolean|nil
function History:_open_file(ci, fi, keep_focus)
    self:_set_expanded(ci, true)
    local files = self:_files(ci)
    if #files == 0 then
        return
    end
    fi = math.max(1, math.min(fi, #files))
    self.index, self.file_index = ci, fi
    self:render()
    self:_move_cursor(self:_file_line(ci, fi))
    vim.api.nvim_set_current_win(self:_ensure_origin())
    self.on_file(self.commits[ci], files[fi])
    if not keep_focus and self:is_open() then
        vim.api.nvim_set_current_win(self.winid)
    end
end

-- <CR>/o: file mode opens the commit under the cursor; range mode toggles a commit's
-- fold (opening its first file on expand) or opens the file under the cursor
---@param keep_focus boolean|nil
function History:select(keep_focus)
    local m = self:_cursor_meta()
    if not m then
        return
    end
    if self.mode == "file" then
        return self:_open(m.ci, keep_focus)
    end
    if m.kind == "commit" then
        if self:_is_expanded(m.ci) then
            self:_set_expanded(m.ci, false)
            self:render()
            self:_move_cursor(self:_commit_line(m.ci))
        else
            self:_open_file(m.ci, 1, keep_focus) -- expand + show the first file
        end
    else
        self:_open_file(m.ci, m.fi, keep_focus)
    end
end

-- za: toggle the fold of the commit under the cursor (or the file row's parent
-- commit), keeping the cursor on the commit line. range mode only
function History:toggle_fold()
    local m = self:_cursor_meta()
    if not m then
        return
    end
    self:_set_expanded(m.ci, not self:_is_expanded(m.ci))
    self:render()
    self:_move_cursor(self:_commit_line(m.ci))
end

-- ]f / [f. file mode: step to the next/previous commit. range mode: step file rows,
-- crossing into the adjacent commit (auto-expanded) at a boundary. `keep_focus`
-- keeps focus in the diff window (in-view stepping)
---@param direction "next"|"prev"
---@param keep_focus boolean|nil
function History:step(direction, keep_focus)
    local fwd = direction == "next"
    if self.mode == "file" then
        local i = self.index + (fwd and 1 or -1)
        if i < 1 or i > #self.commits then
            return
        end
        self:_move_cursor(commit_line(i))
        return self:_open(i, keep_focus)
    end

    local ci = self.index
    local fi = (self.file_index or 1) + (fwd and 1 or -1)
    if fi >= 1 and fi <= #self:_files(ci) then
        return self:_open_file(ci, fi, keep_focus)
    end
    -- crossed the commit boundary: find the adjacent commit that has files
    local step = fwd and 1 or -1
    local ti = ci + step
    while ti >= 1 and ti <= #self.commits do
        local files = self:_files(ti)
        if #files > 0 then
            return self:_open_file(ti, fwd and 1 or #files, keep_focus)
        end
        ti = ti + step
    end
end

-- scroll the *diff view* a quarter page (the origin window), not the panel list,
-- mirroring the file panel (default f / b)
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
    local lines = { " differ file history", "" }
    if self.mode == "range" then
        vim.list_extend(lines, {
            " <CR> / o   open file / toggle fold",
            " za         toggle fold",
            " ]f / [f    next / previous file",
        })
    else
        vim.list_extend(lines, {
            " <CR> / o   show commit",
            " ]f / [f    next / previous commit",
        })
    end
    vim.list_extend(lines, {
        " ]c / [c    next / previous hunk",
        " f / b      scroll diff down / up",
        " g?         this help",
    })
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
        title = " Differ ",
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

    local km = self.keymaps
    local function map(spec, fn, desc)
        bind(self.bufnr, spec, fn, "differ history: " .. desc)
    end
    local item = self.mode == "range" and "file" or "commit"
    map(km.select, function()
        self:select()
    end, "open " .. item)
    map(km.next_file, function()
        self:step("next")
    end, "next " .. item)
    map(km.prev_file, function()
        self:step("prev")
    end, "previous " .. item)
    if self.mode == "range" then
        map(km.toggle_fold, function()
            self:toggle_fold()
        end, "toggle fold")
    end
    map(km.next_hunk, function()
        require("differ").goto_hunk("next")
    end, "next hunk")
    map(km.prev_hunk, function()
        require("differ").goto_hunk("prev")
    end, "previous hunk")
    map(km.help, function()
        self:show_help()
    end, "help")
    map(km.scroll_down, function()
        self:scroll("down")
    end, "scroll down a quarter page")
    map(km.scroll_up, function()
        self:scroll("up")
    end, "scroll up a quarter page")
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

-- open the panel, render, select the newest commit (range: expand it + open its
-- first file), and by default land the cursor in the diff. returns self
---@param keep_focus boolean|nil  -- leave focus in the diff window (default true)
---@return differ.History
function History:open(keep_focus)
    self.origin_win = vim.api.nvim_get_current_win()
    self:_open_window()
    current = self
    if self.mode == "range" then
        self:_set_expanded(1, true)
        self:render()
        self:_open_file(1, 1, keep_focus ~= false)
    else
        self:render()
        self:_move_cursor(commit_line(1))
        self:_open(1, keep_focus ~= false)
    end
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

-- flip absolute <-> relative dates live, keeping the cursor put (runtime control;
-- the default comes from config.relative_dates)
function History:toggle_relative_dates()
    self.relative_dates = not self.relative_dates
    if self:is_open() then
        local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
        self:render()
        pcall(vim.api.nvim_win_set_cursor, self.winid, { lnum, 0 })
    end
end

-- the live history panel, if one is open
---@return differ.History|nil
function History.current()
    return current
end

return History
