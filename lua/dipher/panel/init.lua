-- file panel (§8.6): the persistent sidebar listing a change set. source-agnostic
-- by design: it renders FileEntry sections, owns fold/listing state and the
-- window, and calls `on_select(entry)` when a file is chosen. the local frontend
-- feeds it git changes (phase 2); the PR frontend reuses it verbatim (phase 4),
-- only swapping the model source. it owns *which file*; the View owns *how it
-- renders*, so selecting a file re-sources the existing View (separation of
-- concerns, §8.6). pure tree/line logic lives in panel/tree.lua + panel/render.lua

local tree = require("dipher.panel.tree")
local render = require("dipher.panel.render")
local set_wo = require("dipher.util.win").set_local
local bind = require("dipher.util.keymap").bind

local ns = vim.api.nvim_create_namespace("dipher.panel")
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

---@type dipher.Panel|nil -- the live panel, for runtime API (Panel.current())
local current = nil

-- a `(glyph, hl)` provider backed by nvim-web-devicons, or nil when it's absent
-- (icons degrade away cleanly). resolved once per panel
---@return nil|fun(path: string): string|nil, string|nil
local function devicon_provider()
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if not ok then
        return nil
    end
    return function(path)
        local name = path:match("[^/]+$") or path
        local ext = name:match("%.([^.]+)$")
        return devicons.get_icon(name, ext, { default = true })
    end
end

---@type table<string, string>
local STATUS_HL = {
    A = "dipherPanelAdd",
    M = "dipherPanelModify",
    D = "dipherPanelDelete",
    R = "dipherPanelRename",
    C = "dipherPanelRename",
    U = "dipherPanelUnmerged",
    ["?"] = "dipherPanelUntracked",
}

---@class dipher.panel.Section
---@field title string|nil
---@field entries dipher.FileEntry[]

-- file-level staging hooks (§8.6 slice C); supplied by the local frontend for the
-- working-tree source, nil otherwise (rev-pair lists aren't stageable)
---@class dipher.panel.Actions
---@field stage fun(entry: dipher.FileEntry)
---@field unstage fun(entry: dipher.FileEntry)
---@field stage_all fun()
---@field unstage_all fun()
---@field discard fun(entry: dipher.FileEntry)
---@field reload fun(): dipher.panel.Section[] -- recompute sections after an op

---@class dipher.Panel
---@field bufnr integer
---@field winid integer|nil
---@field origin_win integer|nil
---@field sections dipher.panel.Section[]
---@field listing "tree"|"flat"
---@field collapsed table<string, boolean>
---@field on_select fun(entry: dipher.FileEntry)
---@field on_close fun()|nil
---@field on_external_change fun()|nil
---@field root string|nil
---@field footer string|nil
---@field actions dipher.panel.Actions|nil
---@field keymaps table<string, string|string[]|false>
---@field icon_for nil|fun(path: string): string|nil, string|nil
---@field position string
---@field height integer
---@field width integer
---@field lines string[]
---@field meta dipher.panel.LineMeta[]
---@field augroup integer|nil  -- autocmd group for the external-change refresh
local Panel = {}
Panel.__index = Panel

---@class dipher.panel.Opts
---@field sections dipher.panel.Section[]
---@field on_select fun(entry: dipher.FileEntry)
---@field on_close? fun()  -- runs on :close (e.g. tear down the driven view)
---@field on_external_change? fun() -- re-source list + diff after an outside git change
---@field root? string  -- repo/worktree path shown in the panel header
---@field footer? string -- rev spec shown under "Showing changes for:"
---@field actions? dipher.panel.Actions -- file-level staging hooks (§8.6 slice C)
---@field keymaps? table<string, string|string[]|false> -- resolved panel action -> lhs (§4.3)
---@field icons? boolean -- filetype devicons (default true when available)
---@field listing? "tree"|"flat"
---@field position? "bottom"|"top"|"left"|"right"
---@field height? integer
---@field width? integer

-- build a panel (buffer only; the window is created on :open, so it's headless-
-- constructible for tests)
---@param opts dipher.panel.Opts
---@return dipher.Panel
function Panel.new(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    -- "hide", not "wipe": set_position closes + reopens the window, and the panel
    -- owns the buffer's lifecycle explicitly via :close()
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "dipherpanel"
    vim.bo[bufnr].modifiable = false
    -- name it so the statusline shows "dipher://panel" rather than "[Scratch]"
    -- (#bufnr fallback guards the rare case the bare name is already taken)
    if not pcall(vim.api.nvim_buf_set_name, bufnr, "dipher://panel") then
        pcall(vim.api.nvim_buf_set_name, bufnr, "dipher://panel#" .. bufnr)
    end
    return setmetatable({
        bufnr = bufnr,
        sections = opts.sections,
        on_select = opts.on_select,
        on_close = opts.on_close,
        on_external_change = opts.on_external_change,
        root = opts.root,
        footer = opts.footer,
        actions = opts.actions,
        keymaps = vim.tbl_extend(
            "force",
            require("dipher.config").defaults.keymaps,
            opts.keymaps or {}
        ),
        icon_for = opts.icons ~= false and devicon_provider() or nil,
        listing = opts.listing or "tree",
        position = opts.position or "bottom",
        height = opts.height or 10,
        width = opts.width or 35,
        collapsed = {},
        lines = {},
        meta = {},
    }, Panel)
end

-- 1-based line of the first file row, or 1 if there are none
---@return integer
function Panel:_first_file_line()
    for i, m in ipairs(self.meta) do
        if m.kind == "file" then
            return i
        end
    end
    return 1
end

-- re-flatten the sections (honouring listing + fold state) and repaint the
-- buffer. cursor line is preserved across re-renders (clamped)
function Panel:render()
    local blocks = {}
    for _, sec in ipairs(self.sections) do
        local root = tree.build(sec.entries)
        blocks[#blocks + 1] =
            { title = sec.title, rows = tree.rows(root, self.listing, self.collapsed) }
    end
    local header = self.root and { path = self.root, help = "g?" } or nil
    local out = render.lines(blocks, header, self.icon_for, self.footer)
    self.lines, self.meta = out.lines, out.meta

    vim.bo[self.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, out.lines)
    vim.bo[self.bufnr].modifiable = false
    self:_highlight()
end

-- paint section/dir/status highlights from the line metadata
function Panel:_highlight()
    vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
    for i, m in ipairs(self.meta) do
        local row = i - 1
        local eol = #self.lines[i]
        if m.kind == "root" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = eol, hl_group = "dipherPanelRoot" }
            )
        elseif m.kind == "help" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = eol, hl_group = "dipherPanelHelp" }
            )
        elseif m.kind == "header" or m.kind == "foothead" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = eol, hl_group = "dipherPanelHeader" }
            )
        elseif m.kind == "footrev" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                0,
                { end_col = eol, hl_group = "dipherPanelHelp" }
            )
        elseif m.kind == "dir" then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                ns,
                row,
                m.name_col,
                { end_col = eol, hl_group = "dipherPanelDir" }
            )
        elseif m.kind == "file" then
            local hl = STATUS_HL[m.status]
            if hl then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.status_col,
                    { end_col = m.status_col + #m.status, hl_group = hl }
                )
            end
            if m.icon_col and m.icon_hl then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.icon_col,
                    { end_col = m.icon_end, hl_group = m.icon_hl }
                )
            end
            if m.add_col then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.add_col,
                    { end_col = m.add_end, hl_group = "dipherPanelCountAdd" }
                )
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    ns,
                    row,
                    m.del_col,
                    { end_col = m.del_end, hl_group = "dipherPanelCountDelete" }
                )
            end
        end
    end
end

-- replace the file-list model and repaint (used on refresh / source change)
---@param sections dipher.panel.Section[]
function Panel:set_sections(sections)
    self.sections = sections
    self:render()
end

-- toggle the fold state of a directory path and repaint, keeping the cursor put
---@param path string
function Panel:toggle_fold(path)
    self.collapsed[path] = not self.collapsed[path]
    local lnum = self.winid and vim.api.nvim_win_get_cursor(self.winid)[1] or 1
    self:render()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_win_set_cursor(self.winid, { math.min(lnum, math.max(#self.lines, 1)), 0 })
    end
end

-- a non-panel window to open diffs in: the origin window if still valid, else any
-- other window, else a fresh split carved off the panel
---@return integer
function Panel:_ensure_origin()
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

-- open `entry`'s diff in the main window. by default focus returns to the panel so
-- file browsing keeps flowing; `keep_focus` leaves it in the diff window (used when
-- stepping files from inside the diff via `]f`/`[f`)
---@param entry dipher.FileEntry
---@param keep_focus boolean|nil
function Panel:_open(entry, keep_focus)
    vim.api.nvim_set_current_win(self:_ensure_origin())
    self.on_select(entry)
    if not keep_focus and self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_set_current_win(self.winid)
    end
end

-- <CR>/o: open a file, or toggle a directory's fold. `keep_focus` leaves the cursor
-- in the diff window (used by the open-and-show entry so :Dipher lands you in the diff)
---@param keep_focus boolean|nil
function Panel:select(keep_focus)
    local m = self.meta[vim.api.nvim_win_get_cursor(self.winid)[1]]
    if not m then
        return
    end
    if m.kind == "dir" then
        self:toggle_fold(m.path)
    elseif m.kind == "file" then
        self:_open(m.entry, keep_focus)
    end
end

-- the FileEntry under the cursor, or nil if the cursor isn't on a file row
---@return dipher.FileEntry|nil
function Panel:_cursor_entry()
    local m = self.winid and self.meta[vim.api.nvim_win_get_cursor(self.winid)[1]]
    return m and m.kind == "file" and m.entry or nil
end

-- re-read the model (after a stage op or on focus) and repaint, keeping the cursor
-- line (clamped). no-op without staging actions (rev-pair panels aren't reloadable)
function Panel:refresh()
    if not self.actions or not self:is_open() then
        return
    end
    local lnum = self.winid and vim.api.nvim_win_get_cursor(self.winid)[1] or 1
    self:set_sections(self.actions.reload())
    self:_restore_cursor(lnum)
end

-- s/u/S/U: stage or unstage the file under the cursor (or all), then refresh
---@param op "stage"|"unstage"|"stage_all"|"unstage_all"
function Panel:stage_op(op)
    if not self.actions then
        return
    end
    if op == "stage_all" or op == "unstage_all" then
        self.actions[op]()
    else
        local entry = self:_cursor_entry()
        if not entry then
            return
        end
        self.actions[op](entry)
    end
    self:refresh()
end

-- X: discard the file under the cursor after a confirm (destructive), then refresh
function Panel:discard()
    if not self.actions then
        return
    end
    local entry = self:_cursor_entry()
    if not entry then
        return
    end
    local choice = vim.fn.confirm(("Discard changes to %s?"):format(entry.path), "&Yes\n&No", 2)
    if choice == 1 then
        self.actions.discard(entry)
        self:refresh()
    end
end

-- ]f / [f: move to the next/prev file row and open it (lockstep file stepping).
-- `keep_focus` is threaded to `_open` so in-view stepping stays in the diff window
---@param direction "next"|"prev"
---@param keep_focus boolean|nil
function Panel:goto_file(direction, keep_focus)
    local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
    local from, to, step = lnum + 1, #self.meta, 1
    if direction == "prev" then
        from, to, step = lnum - 1, 1, -1
    end
    for i = from, to, step do
        local m = self.meta[i]
        if m and m.kind == "file" then
            vim.api.nvim_win_set_cursor(self.winid, { i, 0 })
            self:_open(m.entry, keep_focus)
            return
        end
    end
end

-- scroll the *diff view* a quarter page (the origin window, where the file renders),
-- not the panel list, mirroring diffview's file-panel scroll (default f / b)
---@param direction "down"|"up"
function Panel:scroll(direction)
    local win = self.origin_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local n = math.max(1, math.floor(vim.api.nvim_win_get_height(win) / 4))
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! " .. n .. (direction == "down" and CTRL_D or CTRL_U))
    end)
end

-- g?: a floating keymap cheatsheet, dismissed with <Esc> / g?
function Panel:show_help()
    local lines = {
        " dipher panel",
        "",
        " <CR> / o   open file / toggle fold",
        " ]f / [f    next / previous file",
        " ]c / [c    next / previous hunk",
        " f / b      scroll diff down / up",
    }
    if self.actions then
        vim.list_extend(lines, {
            " s / u      stage / unstage file",
            " S / U      stage / unstage all",
            " X          discard file (confirm)",
            " R          refresh",
        })
    end
    vim.list_extend(lines, { " g?         this help" })
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
function Panel:_setup_window()
    local win = self.winid
    -- window-local only: a plain vim.wo[win] write also sets the global default
    -- (omits scope), leaking the panel's chrome onto every other window
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
        bind(self.bufnr, spec, fn, "dipher panel: " .. desc)
    end
    map(km.select, function()
        self:select()
    end, "open / toggle fold")
    map(km.next_file, function()
        self:goto_file("next")
    end, "next file")
    map(km.prev_file, function()
        self:goto_file("prev")
    end, "previous file")
    -- next/prev hunk drive the diff view's hunk nav from the panel (bound buffer-
    -- locally in the diff window too), so hunk stepping works from either side
    map(km.next_hunk, function()
        require("dipher").goto_hunk("next")
    end, "next hunk")
    map(km.prev_hunk, function()
        require("dipher").goto_hunk("prev")
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
    if self.actions then
        map(km.stage, function()
            self:stage_op("stage")
        end, "stage file")
        map(km.unstage, function()
            self:stage_op("unstage")
        end, "unstage file")
        map(km.stage_all, function()
            self:stage_op("stage_all")
        end, "stage all")
        map(km.unstage_all, function()
            self:stage_op("unstage_all")
        end, "unstage all")
        map(km.discard, function()
            self:discard()
        end, "discard file")
        map(km.refresh, function()
            self:refresh()
        end, "refresh")
    end
end

-- create the split in the configured position, bind the buffer, set window opts
function Panel:_open_window()
    if self.position == "top" then
        vim.cmd(("topleft %dsplit"):format(self.height))
    elseif self.position == "left" then
        vim.cmd(("topleft %dvsplit"):format(self.width))
    elseif self.position == "right" then
        vim.cmd(("botright %dvsplit"):format(self.width))
    else -- bottom (default)
        vim.cmd(("botright %dsplit"):format(self.height))
    end
    self.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winid, self.bufnr)
    self:_setup_window()
end

-- close the panel window but keep the buffer + state (for re-positioning)
function Panel:_close_window()
    if self:is_open() then
        pcall(vim.api.nvim_win_close, self.winid, true)
    end
    self.winid = nil
end

-- open the panel in its position and focus it
---@return dipher.Panel
function Panel:open()
    self.origin_win = vim.api.nvim_get_current_win()
    self:_open_window()
    self:render()
    vim.api.nvim_win_set_cursor(self.winid, { self:_first_file_line(), 0 })
    self:_watch_external_changes()
    current = self
    return self
end

-- refresh when git state may have changed outside dipher, without a manual R.
-- FocusGained: back from another app / tmux pane. ShellCmdPost: an in-nvim `:!git`.
-- TermClose / TermLeave: a terminal UI like lazygit run in a float, which never
-- drops nvim's own OS focus so FocusGained doesn't fire. the refresh is scheduled so
-- it runs once the terminal window has finished tearing down. only worktree-status
-- panels reload; rev-pair lists don't track the worktree. FocusGained needs
-- `focus-events on` under tmux
function Panel:_watch_external_changes()
    if not self.actions then
        return
    end
    self.augroup = vim.api.nvim_create_augroup("dipher.panel." .. self.bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost", "TermClose", "TermLeave" }, {
        group = self.augroup,
        desc = "dipher: refresh the panel when git state changed externally",
        callback = function()
            vim.schedule(function()
                if not self:is_open() then
                    return
                end
                -- on_external_change re-sources the diff too; refresh() is the list-only
                -- fallback for a panel without the hook
                if self.on_external_change then
                    self.on_external_change()
                else
                    self:refresh()
                end
            end)
        end,
    })
end

---@return boolean
function Panel:is_open()
    return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

-- restore the cursor line after a re-render/reposition (clamped to the content)
---@param lnum integer
function Panel:_restore_cursor(lnum)
    if self:is_open() then
        pcall(
            vim.api.nvim_win_set_cursor,
            self.winid,
            { math.min(lnum, math.max(#self.lines, 1)), 0 }
        )
    end
end

-- runtime API (§8.3-style per-view control, not setup config) ----------------

-- switch tree <-> flat listing live
---@param listing "tree"|"flat"
function Panel:set_listing(listing)
    self.listing = listing
    if self:is_open() then
        local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
        self:render()
        self:_restore_cursor(lnum)
    end
end

function Panel:toggle_listing()
    self:set_listing(self.listing == "tree" and "flat" or "tree")
end

-- move the panel to a new position live, preserving the buffer, fold state, and
-- the main (origin) window
---@param position "bottom"|"top"|"left"|"right"
function Panel:set_position(position)
    self.position = position
    if not self:is_open() then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(self.winid)[1]
    local origin = self.origin_win
    self:_close_window()
    if origin and vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
    end
    self:_open_window()
    self.origin_win = origin
    self:render()
    self:_restore_cursor(lnum)
end

-- close the panel window and wipe its buffer. `on_close` (if set) tears down the
-- diff view the panel drives, so closing the panel ends the whole dipher session
function Panel:close()
    self:_close_window()
    if self.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
        self.augroup = nil
    end
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

-- the live panel, if one is open: the entry point for the runtime API
---@return dipher.Panel|nil
function Panel.current()
    return current
end

return Panel
