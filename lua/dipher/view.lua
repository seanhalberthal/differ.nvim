-- view lifecycle: own one derived buffer per render column, lay them into windows
-- (one for stacked, a scroll-bound pair for split), and hold each column's map.
-- buffers + maps are regenerated atomically on re-render; the gutter rail, the
-- diff highlight layer, and the treesitter syntax pass (§6.5) are refreshed from
-- the map; overlays are extmark-only

local render = require("dipher.render")
local paint = require("dipher.ui.paint")
local syntax = require("dipher.syntax")
local statuscolumn = require("dipher.ui.statuscolumn")
local nav = require("dipher.nav")
local bind = require("dipher.util.keymap").bind

local ns = vim.api.nvim_create_namespace("dipher")
local staged_ns = vim.api.nvim_create_namespace("dipher.staging")
local cursor_ns = vim.api.nvim_create_namespace("dipher.cursorline")
local STATUSCOLUMN_EXPR = '%!v:lua.require("dipher.ui.statuscolumn").render()'
local FOLDTEXT_EXPR = 'v:lua.require("dipher.ui.foldtext").render()'
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

local set_wo = require("dipher.util.win").set_local

---@type table<integer, dipher.View> -- bufnr -> owning view, for command dispatch
local by_buf = {}

-- monotonic per-view id, for a stable per-view augroup name (the close guard)
local view_seq = 0
local function next_id()
    view_seq = view_seq + 1
    return view_seq
end

-- the most recently laid-out view: only it owns the diff-window-close teardown. there
-- is one live session at a time, so a superseded view's stale WinClosed (window ids get
-- recycled) must not tear down a newer session
local armed_view = nil

---@class dipher.ViewColumn
---@field bufnr integer
---@field winid integer|nil
---@field map dipher.LineMap
---@field side dipher.ColumnSide

-- the hunk-staging capability the git frontend supplies per source (§8.1). the
-- view keeps its diff frozen and marks staged hunks in place rather than re-reading
-- git, so it tracks per-hunk state and calls `apply` to patch one hunk: `reverse`
-- false stages, true unstages, `offset` shifts past already-staged hunks before it.
-- `initial` is every hunk's opening state (an unstaged diff opens unstaged, a staged
-- one opens staged). `apply` patches one hunk and returns ok; `refresh` repaints the
-- panel counts and is called once after a single toggle or a whole S/U batch
---@class dipher.view.Staging
---@field initial "staged"|"unstaged"
---@field apply fun(model: dipher.DiffModel, hunk: dipher.Hunk, offset: integer, reverse: boolean): boolean
---@field refresh fun()

---@class dipher.View
---@field columns dipher.ViewColumn[]
---@field model dipher.DiffModel
---@field layout dipher.Layout
---@field context integer
---@field wrap boolean  -- soft-wrap long lines in the diff windows
---@field counter boolean  -- hunk-counter winbar on the diff windows
---@field deep_diff table
---@field keymaps table
---@field can_stage boolean  -- session-level: bind s/u (worktree-status panels)
---@field staging dipher.view.Staging|nil  -- per-source capability (nil off-side)
---@field staged_hunks table<integer, boolean>  -- hunk index -> staged, for marking
---@field on_edit_unstage fun(path: string)|nil  -- frontend hook: unstage + re-source for edit-in-review
---@field edit_win integer|nil  -- transient editable real-file window (edit-in-review, §8.1)
---@field id integer  -- per-view id, for the close-guard augroup name
---@field _suppress_close boolean  -- true while we close a diff window ourselves (relayout/teardown)
---@field _closing boolean  -- re-entrancy guard once a user close has begun
---@field _close_group integer|nil  -- augroup id for the WinClosed close guard
local View = {}
View.__index = View

---@class dipher.view.Opts
---@field layout dipher.Layout
---@field context integer
---@field wrap? boolean
---@field counter? boolean
---@field deep_diff table
---@field keymaps? table
---@field staging? dipher.view.Staging
---@field can_stage? boolean
---@field on_edit_unstage? fun(path: string)

-- build a view for a model. buffers and data are created here; windows are not
-- touched until :open(), so a View can be constructed headlessly for tests
---@param model dipher.DiffModel
---@param opts dipher.view.Opts
---@return dipher.View
function View.new(model, opts)
    local self = setmetatable({
        columns = {},
        model = model,
        layout = opts.layout,
        context = opts.context,
        wrap = opts.wrap ~= false, -- default on; only an explicit false disables it
        counter = opts.counter ~= false, -- default on; only an explicit false disables it
        deep_diff = opts.deep_diff,
        -- the diff surface's resolved action -> lhs map; default to the shared
        -- defaults so a directly-constructed View still binds (merge keeps partials)
        keymaps = vim.tbl_extend(
            "force",
            require("dipher.config").defaults.keymaps,
            opts.keymaps or {}
        ),
        can_stage = opts.can_stage or false,
        staging = opts.staging,
        on_edit_unstage = opts.on_edit_unstage,
        staged_hunks = {},
        id = next_id(),
        _suppress_close = false,
        _closing = false,
    }, View)
    self:_init_staged()
    self:rerender(opts)
    return self
end

-- seed per-hunk staged state for the current source: a staged diff (HEAD↔index)
-- opens with every hunk staged, an unstaged diff (index↔worktree) with none
function View:_init_staged()
    self.staged_hunks = {}
    if self.staging and self.staging.initial == "staged" then
        for i = 1, #self.model.hunks do
            self.staged_hunks[i] = true
        end
    end
end

-- a stable, file-shaped buffer name so the statusline/winbar shows the file path
-- instead of `[Scratch]` (§8.1). the `dipher://` scheme keeps it distinct from the
-- real file (a bare relative name would resolve to the same absolute path and
-- collide) and marks it non-editable; the path stays last so `:t` is the basename.
-- the default stacked view is just `dipher://<path>`; a split's two columns get an
-- old/new segment to stay distinct
---@param model dipher.DiffModel
---@param side dipher.ColumnSide
---@return string
local function buf_name(model, side)
    if side == "unified" then
        return "dipher://" .. model.path
    end
    return ("dipher://%s/%s"):format(side, model.path)
end

-- name `bufnr` for `side`, falling back to a bufnr-suffixed name if that exact
-- name is somehow already taken (E95), e.g. a second concurrent view
---@param bufnr integer
---@param model dipher.DiffModel
---@param side dipher.ColumnSide
local function name_buffer(bufnr, model, side)
    local name = buf_name(model, side)
    if not pcall(vim.api.nvim_buf_set_name, bufnr, name) then
        pcall(vim.api.nvim_buf_set_name, bufnr, name .. "#" .. bufnr)
    end
end

-- give the buffer the file's filetype so the statusline / lualine shows it, but
-- keep native treesitter and regex syntax off: the buffer holds interleaved
-- old+new lines that aren't valid source, and dipher paints its own syntax pass
-- through the line map (§6.5), so a native highlighter would only mangle it
---@param bufnr integer
---@param path string
local function set_filetype(bufnr, path)
    local ft = vim.filetype.match({ filename = path }) or ""
    if vim.bo[bufnr].filetype ~= ft then
        vim.bo[bufnr].filetype = ft
    end
    pcall(vim.treesitter.stop, bufnr)
    vim.bo[bufnr].syntax = "OFF"
end

-- gitsigns never attaches to our synthetic buffers, so a lualine that reads its
-- status dict shows no branch/diffstat. populate those vars ourselves from the
-- model: counts come from the hunks, the branch from model.head (frontend-set)
---@param bufnr integer
---@param model dipher.DiffModel
local function set_git_status(bufnr, model)
    local added, changed, removed = 0, 0, 0
    for _, h in ipairs(model.hunks) do
        local common = math.min(h.old_count, h.new_count)
        changed = changed + common
        added = added + (h.new_count - common)
        removed = removed + (h.old_count - common)
    end
    vim.b[bufnr].gitsigns_status_dict =
        { added = added, changed = changed, removed = removed, head = model.head }
    vim.b[bufnr].gitsigns_head = model.head
end

-- the map for a side, or the unified map. consumers (]c, staging, comment
-- anchoring) read this rather than branching on layout themselves
---@param side dipher.ColumnSide
---@return dipher.LineMap|nil
function View:map_for(side)
    for _, col in ipairs(self.columns) do
        if col.side == side or col.side == "unified" then
            return col.map
        end
    end
    return nil
end

-- re-render the active model and atomically replace each column's content, map,
-- gutter rail, and highlight layer. window layout is unchanged; if a re-render
-- changes the column count (a layout toggle), call :open() to relayout
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
function View:rerender(opts)
    self.layout = opts.layout
    self.context = opts.context
    self.deep_diff = opts.deep_diff
    local result = render.render(self.model, opts)

    for i, col in ipairs(result.columns) do
        local existing = self.columns[i]
        local bufnr = existing and existing.bufnr or vim.api.nvim_create_buf(false, true)
        name_buffer(bufnr, self.model, col.side)
        set_filetype(bufnr, self.model.path)
        set_git_status(bufnr, self.model)
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, col.lines)
        vim.bo[bufnr].modifiable = false
        paint.apply(bufnr, ns, col)
        syntax.apply(bufnr, col, self.model)
        statuscolumn.set(bufnr, statuscolumn.format(col))
        self.columns[i] = {
            bufnr = bufnr,
            winid = existing and existing.winid or nil,
            map = col.map,
            side = col.side,
            folds = col.folds,
        }
        by_buf[bufnr] = self
    end
    -- shrinking column count (split -> stacked): drop the surplus buffers/windows
    for i = #result.columns + 1, #self.columns do
        self:_discard(self.columns[i])
        self.columns[i] = nil
    end
    self:_paint_staged() -- overlay marks for staged hunks (no-op off a staging view)
    self:_paint_cursorline() -- our cursor-line overlay (no-op until windows exist)
    -- folds are a window concern, not buffer content: the callers that change the
    -- ranges or the windows reapply them (set_context/set_source in place, _relayout
    -- on open / layout toggle), so rerender doesn't, avoiding a double-apply
end

-- overlay the staged-hunk marks (§8.1): a muted full-line bg over every line of a
-- staged hunk plus the gutter glyph. repainted on every render and on each toggle;
-- buffer content is untouched (the diff stays frozen). a no-op off a staging view,
-- which leaves the gutter at its normal width
function View:_paint_staged()
    if not self.can_stage then
        return
    end
    for _, col in ipairs(self.columns) do
        vim.api.nvim_buf_clear_namespace(col.bufnr, staged_ns, 0, -1)
        local staged_lines = {}
        for i, line in ipairs(col.map.lines) do
            if line.hunk and self.staged_hunks[line.hunk] then
                vim.api.nvim_buf_set_extmark(col.bufnr, staged_ns, i - 1, 0, {
                    line_hl_group = "dipherStagedLine",
                    priority = 150, -- above the add/delete bg (100), under word spans (200)
                })
                staged_lines[i] = true
            end
        end
        statuscolumn.set_staged(col.bufnr, staged_lines)
    end
end

-- repaint our own cursor line above the diff backgrounds, since a no-foreground
-- CursorLine is low-priority and gets buried by them. mirrors the diff line bg
-- (a char-level fill with hl_eol so it spans the whole row past EOL) but at a higher
-- priority so it wins; bg-only, so syntax foreground and word spans still show
-- through. cleared from every column and painted only in the focused one (the cursor
-- lives in one column), so the off-side column shows none. driven by CursorMoved /
-- WinEnter and after each render
function View:_paint_cursorline()
    for _, col in ipairs(self.columns) do
        if col.bufnr and vim.api.nvim_buf_is_valid(col.bufnr) then
            vim.api.nvim_buf_clear_namespace(col.bufnr, cursor_ns, 0, -1)
        end
    end
    local col = self:_focused_column()
    local win = col and col.winid
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    vim.api.nvim_buf_set_extmark(col.bufnr, cursor_ns, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = "dipherCursorLine",
        hl_eol = true, -- fill past EOL so the whole row is covered, like the diff bg
        priority = 160, -- above the add/delete bg (100); word spans (200) show through
    })
end

-- the net line-count delta of the staged hunks before `idx`: the frozen view's
-- line numbers are from open time, but git applies against the live index, where
-- each already-staged earlier hunk has shifted positions by its added/removed lines
---@param idx integer
---@return integer
function View:_stage_offset(idx)
    local off = 0
    for j = 1, idx - 1 do
        if self.staged_hunks[j] then
            local h = self.model.hunks[j]
            off = off + (h.new_count - h.old_count)
        end
    end
    return off
end

-- (re)create the native folds for each column's window from its fold ranges, left
-- open by default (the structure stays so zc/za collapse them on demand). reapplied
-- only where the ranges or windows change: a context change (d= / d-), a file switch,
-- a layout toggle, and open; never on scroll or redraw. with context = full the
-- renderer returns no ranges.
function View:_apply_folds()
    for _, col in ipairs(self.columns) do
        local win = col.winid
        if win and vim.api.nvim_win_is_valid(win) then
            set_wo(win, "foldmethod", "manual")
            set_wo(win, "foldtext", FOLDTEXT_EXPR)
            set_wo(win, "foldenable", true)
            vim.api.nvim_win_call(win, function()
                vim.cmd("silent! normal! zE") -- drop existing folds before rebuilding
                for _, f in ipairs(col.folds or {}) do
                    if f.last > f.first then
                        vim.cmd(("silent! %d,%dfold"):format(f.first, f.last))
                    end
                end
                vim.cmd("silent! normal! zR") -- open by default; the structure stays for zc/za
            end)
        end
    end
end

-- the view owning the current buffer, if any. commands dispatch through this
---@return dipher.View|nil
function View.current()
    return by_buf[vim.api.nvim_get_current_buf()]
end

-- the view owning `bufnr`, if any. lets the panel reach the diff view it drives
-- (via its origin window's buffer) so panel-side keys act on that view
---@param bufnr integer
---@return dipher.View|nil
function View.for_buf(bufnr)
    return by_buf[bufnr]
end

-- whether the view's primary window is still alive (panel uses this to decide
-- between re-sourcing in place and opening fresh)
---@return boolean
function View:is_open()
    local col = self.columns[1]
    return col ~= nil and col.winid ~= nil and vim.api.nvim_win_is_valid(col.winid)
end

-- swap the diffed file in place: same windows/layout/context, new model. the
-- panel calls this when a different file is selected so the View is re-sourced,
-- not recreated (§8.6 separation of concerns). column count is layout-determined,
-- so it never changes here, no relayout. `staging` rides along because the stage
-- direction is per-file (a staged entry unstages, an unstaged one stages).
-- `opts.focus_line` is a new-side file line to snap to (a re-source of the same
-- file underneath the user); without it the cursor lands on the first unstaged hunk
---@param model dipher.DiffModel
---@param staging dipher.view.Staging|nil
---@param opts? { focus_line?: integer }
function View:set_source(model, staging, opts)
    -- a switch to a different file leaves any edit window stale; drop it. a same-file
    -- re-source (the watcher after a `:w`) keeps it so editing continues uninterrupted
    if self.edit_win and self.model.path ~= model.path then
        self:_release_edit_window()
    end
    self.model = model
    self.staging = staging
    self:_init_staged() -- a new file: reseed staged state from the fresh git read
    self:rerender({ layout = self.layout, context = self.context, deep_diff = self.deep_diff })
    self:_apply_folds() -- new file's ranges; windows unchanged so refold in place
    if opts and opts.focus_line then
        self:focus_new_line(opts.focus_line, true) -- hold the precise line across a refresh
    else
        self:_focus_first_hunk() -- land on the first unstaged hunk of the new file
    end
end

-- swap the layout for this view (a pure re-render behind the map contract, §8.3).
-- column count changes (1 <-> 2), so re-lay the windows after
---@param layout dipher.Layout
function View:set_layout(layout)
    if layout == self.layout then
        return
    end
    self:rerender({ layout = layout, context = self.context, deep_diff = self.deep_diff })
    self:_relayout()
end

-- flip stacked <-> split
function View:toggle_layout()
    self:set_layout(self.layout == "stacked" and "split" or "stacked")
end

-- set the per-view context line count (math.huge = whole file). same column
-- count, so no relayout, content/map/gutter/highlights refresh in place
---@param n integer
function View:set_context(n)
    self:rerender({ layout = self.layout, context = n, deep_diff = self.deep_diff })
    self:_apply_folds() -- ranges shifted with the context; windows unchanged
end

-- widen/narrow context by `delta`. no-op while whole-file (can't decrement ∞)
---@param delta integer
function View:adjust_context(delta)
    if self.context == math.huge then
        return
    end
    self:set_context(math.max(0, self.context + delta))
end

-- per-window appearance + buffer-local motions. our own dual-rail gutter replaces
-- the native gutter; ]c / [c jump between hunks via the active column's map
---@param winid integer
---@param bufnr integer
function View:_setup_window(winid, bufnr)
    vim.api.nvim_win_set_buf(winid, bufnr)
    set_wo(winid, "number", false)
    set_wo(winid, "relativenumber", false)
    set_wo(winid, "signcolumn", "no")
    set_wo(winid, "foldcolumn", "0")
    set_wo(winid, "wrap", self.wrap)
    if self.counter then
        -- a `%!` expression so the hunk count tracks the cursor on every redraw
        set_wo(winid, "winbar", '%!v:lua.require("dipher.ui.winbar").diff()')
    end
    set_wo(winid, "scrollbind", false) -- cleared default; split re-enables it in :open
    set_wo(winid, "statuscolumn", STATUSCOLUMN_EXPR)
    -- own the cursor line: a no-fg CursorLine is low-priority and lost under the diff
    -- backgrounds, so repaint it as an extmark on cursor move / window focus
    local group = vim.api.nvim_create_augroup("dipher.cursorline." .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "BufEnter" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            self:_paint_cursorline()
        end,
    })
    local km = self.keymaps
    bind(bufnr, km.next_hunk, function()
        self:goto_hunk("next")
    end, "dipher: next hunk")
    bind(bufnr, km.prev_hunk, function()
        self:goto_hunk("prev")
    end, "dipher: previous hunk")
    bind(bufnr, km.more_context, function()
        self:adjust_context(1)
    end, "dipher: more context")
    bind(bufnr, km.less_context, function()
        self:adjust_context(-1)
    end, "dipher: less context")
    -- go-to-file (§8.1): leave the session and open the real file. available wherever
    -- the source is file-backed (jump_to_file notifies if not)
    bind(bufnr, km.goto_file, function()
        self:jump_to_file()
    end, "dipher: go to the real file")
    -- edit-in-review (§8.1): only on an uncommitted diff (worktree or staged), where
    -- the file on disk is editable. rev-pair / history / PR diffs aren't
    if self:_editable_source() then
        bind(bufnr, km.edit_file, function()
            self:edit_file()
        end, "dipher: edit the real file")
    end
    -- next/prev file drive the file panel's (or history's) selection in lockstep,
    -- keeping focus here in the diff window (no-op when neither is open)
    bind(bufnr, km.next_file, function()
        self:step_file("next")
    end, "dipher: next file")
    bind(bufnr, km.prev_file, function()
        self:step_file("prev")
    end, "dipher: previous file")
    -- scroll defaults to f/b, which shadow native find-char / back-word (set false)
    bind(bufnr, km.scroll_down, function()
        self:quarter_scroll("down")
    end, "dipher: scroll down a quarter page")
    bind(bufnr, km.scroll_up, function()
        self:quarter_scroll("up")
    end, "dipher: scroll up a quarter page")
    -- stage / unstage the hunk under the cursor (§8.1), hunk-level here vs file-level
    -- in the panel. bound for the whole worktree-status session; the per-file
    -- direction is checked at call time (the buffer is read-only, so shadowing native
    -- substitute / undo is harmless)
    if self.can_stage then
        bind(bufnr, km.stage, function()
            self:stage_hunk()
        end, "dipher: stage hunk")
        bind(bufnr, km.unstage, function()
            self:unstage_hunk()
        end, "dipher: unstage hunk")
        bind(bufnr, km.stage_all, function()
            self:stage_all()
        end, "dipher: stage all hunks")
        bind(bufnr, km.unstage_all, function()
            self:unstage_all()
        end, "dipher: unstage all hunks")
    end
end

-- step the file panel's selection (and re-source this view) without leaving the diff
-- window, the in-view counterpart to the panel's own ]f / [f. `wrap` defaults on (for
-- ]f / [f); the staging review flow passes false so s/S/u/U stop at the list ends
---@param direction "next"|"prev"
---@param wrap? boolean
function View:step_file(direction, wrap)
    local panel = require("dipher.panel").current()
    if panel and panel:is_open() then
        panel:goto_file(direction, true, wrap) -- keep focus in the diff window
        return
    end
    -- file history (§8.4): one file, so ]f / [f step commits instead
    local history = require("dipher.history").current()
    if history and history:is_open() then
        history:step(direction, true)
        return
    end
    -- sidebar hidden but the panel session is live: step from internal selection so
    -- ]f / [f still walk files with no panel window to read the cursor from
    if panel then
        panel:goto_file(direction, true, wrap)
    end
end

-- scroll a quarter of the window height, cursor following (count-prefixed <C-d>/
-- <C-u>, which clamp at the buffer ends)
---@param direction "down"|"up"
function View:quarter_scroll(direction)
    local n = math.max(1, math.floor(vim.api.nvim_win_get_height(0) / 4))
    vim.api.nvim_feedkeys(n .. (direction == "down" and CTRL_D or CTRL_U), "nx", false)
end

-- the column whose window is currently focused, defaulting to the first. split
-- can focus either pane, so motions/jumps read this rather than assuming column 1
---@return dipher.ViewColumn
function View:_focused_column()
    local win = vim.api.nvim_get_current_win()
    for _, c in ipairs(self.columns) do
        if c.winid == win then
            return c
        end
    end
    return self.columns[1]
end

-- move the cursor to the next/prev hunk in the focused column. no-op (silent) at
-- the first/last hunk, matching vim diff-mode motions
---@param direction "next"|"prev"
function View:goto_hunk(direction)
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local lnum = vim.api.nvim_win_get_cursor(col.winid or win)[1]
    -- explicit branch, not `a and next() or prev()`: next_hunk returns nil at the
    -- last hunk, which the and/or idiom would wrongly fall through to prev_hunk
    local target
    if direction == "next" then
        target = nav.next_hunk(col.map, lnum)
    else
        target = nav.prev_hunk(col.map, lnum)
    end
    if target then
        vim.api.nvim_win_set_cursor(col.winid or win, { target, 0 })
    elseif direction == "next" then
        self:step_file("next", false) -- past the last hunk: flow into the next file (no wrap)
    else
        local before = self.model.path
        self:step_file("prev", false) -- before the first hunk: flow into the previous file
        if self.model.path ~= before then
            self:_focus_last_hunk() -- land on its last hunk, continuing the backward flow
        end
    end
end

-- the buffer line to land on when a file opens (§8.1): the start of the first
-- unstaged hunk, the natural place to begin reviewing, falling back to the first
-- hunk when everything is already staged, or nil for a file with no hunks
---@param col dipher.ViewColumn
---@return integer|nil
function View:_first_review_line(col)
    local first_hunk
    for i, line in ipairs(col.map.lines) do
        if line.hunk then
            first_hunk = first_hunk or i
            if not self.staged_hunks[line.hunk] then
                return i
            end
        end
    end
    return first_hunk
end

-- move the primary window's cursor to the first unstaged hunk (or first hunk). run
-- on open and on every file switch so ]f / [f and selecting a file drop you on the
-- first thing to review rather than wherever the cursor happened to be
function View:_focus_first_hunk()
    local col = self.columns[1]
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return
    end
    local lnum = self:_first_review_line(col)
    if lnum then
        pcall(vim.api.nvim_win_set_cursor, col.winid, { lnum, 0 })
    end
end

-- the new-side file line the cursor currently sits on, for holding position across
-- an in-place re-source (an external refresh of the same file). read from the new-
-- side column (the unified column in stacked, the right column in split) so it pairs
-- with focus_new_line; nil when there's no live new side
---@return integer|nil
function View:cursor_new_line()
    -- while editing, the live position is in the edit window (the real worktree file,
    -- which is the new side), so use its line directly; the diff window's own cursor is
    -- stale there. this makes a post-`:w` re-source focus the line just edited
    if self.edit_win and vim.api.nvim_win_is_valid(self.edit_win) then
        return vim.api.nvim_win_get_cursor(self.edit_win)[1]
    end
    local col = self.columns[#self.columns]
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return nil
    end
    local lnum = vim.api.nvim_win_get_cursor(col.winid)[1]
    return nav.file_line(col.map, lnum)
end

-- position the new side near `new_lnum` (where the cursor was, or the line just
-- edited) across an in-place re-source. with `exact` (a re-source holding the precise
-- line), when that line maps to a rendered *changed* line, land on it and centre it so
-- an edit deep in a hunk shows the edit, not the hunk's top. otherwise (or an
-- unchanged/context line) fall back to the nearest hunk's start, landing on the change
-- you were by (this is what open-on-origin wants)
---@param new_lnum integer
---@param exact? boolean
function View:focus_new_line(new_lnum, exact)
    local col = self.columns[#self.columns] -- the new side: the unified col, or right in split
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return
    end
    -- the line maps straight to a rendered changed line (e.g. the line just edited)
    local at = col.map.from_new[new_lnum]
    if exact and at and col.map.lines[at] and col.map.lines[at].hunk then
        pcall(vim.api.nvim_win_set_cursor, col.winid, { at, 0 })
        pcall(vim.api.nvim_win_call, col.winid, function()
            vim.cmd("normal! zz")
        end)
        return
    end
    local hunks = self.model.hunks
    if #hunks == 0 then
        return
    end
    local best, best_dist = 1, nil
    for idx, h in ipairs(hunks) do
        local lo, hi = h.new_start, h.new_start + math.max(h.new_count, 1) - 1
        local dist = 0
        if new_lnum < lo then
            dist = lo - new_lnum
        elseif new_lnum > hi then
            dist = new_lnum - hi
        end
        if not best_dist or dist < best_dist then
            best, best_dist = idx, dist
        end
    end
    for i, line in ipairs(col.map.lines) do
        if line.hunk == best then
            pcall(vim.api.nvim_win_set_cursor, col.winid, { i, 0 })
            return
        end
    end
end

-- the buffer line of the last hunk's start, where the backward review flow lands
-- when stepping into a previous file (so u keeps moving backward through it)
---@param col dipher.ViewColumn
---@return integer|nil
function View:_last_hunk_line(col)
    local last = #self.model.hunks
    if last == 0 then
        return nil
    end
    for i, line in ipairs(col.map.lines) do
        if line.hunk == last then
            return i
        end
    end
    return nil
end

-- move the primary window's cursor to the last hunk (backward file-step landing)
function View:_focus_last_hunk()
    local col = self.columns[1]
    if not (col and col.winid and vim.api.nvim_win_is_valid(col.winid)) then
        return
    end
    local lnum = self:_last_hunk_line(col)
    if lnum then
        pcall(vim.api.nvim_win_set_cursor, col.winid, { lnum, 0 })
    end
end

-- the index of the hunk the cursor sits in, via the focused column's map (§8.1
-- staging). nil on a context / meta / unchanged line that belongs to no hunk
---@return integer|nil
function View:_hunk_index_under_cursor()
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local line = col.map.lines[vim.api.nvim_win_get_cursor(win)[1]]
    return line and line.hunk or nil
end

-- patch hunk `idx` to `want_staged` in the index from the frozen hunk model (never
-- buffer text), shifted past the hunks staged before it, and mark it. no panel
-- refresh / repaint, so callers can batch. returns whether it changed
---@param idx integer
---@param want_staged boolean
---@return boolean
function View:_apply_hunk(idx, want_staged)
    if (self.staged_hunks[idx] or false) == want_staged then
        return false
    end
    local offset = self:_stage_offset(idx)
    -- reverse unstages: we patch away a change currently in the index
    if self.staging.apply(self.model, self.model.hunks[idx], offset, not want_staged) then
        self.staged_hunks[idx] = want_staged
        return true
    end
    return false
end

-- s: stage the hunk under the cursor, or advance if there's nothing to stage here.
-- the review flow (§8.1): the first s on a hunk stages it (staying put so the mark
-- is visible), a second s (now staged) moves to the next hunk, and at the last hunk
-- it steps to the next file, which opens on its first unstaged hunk. so repeated s
-- walks the whole change set, accepting hunk by hunk
function View:stage_hunk()
    if not (self.can_stage and self.staging) then
        return vim.notify("dipher: hunk staging isn't available here", vim.log.levels.WARN)
    end
    local idx = self:_hunk_index_under_cursor()
    if idx and not (self.staged_hunks[idx] or false) then
        self:_toggle_hunk(true)
    else
        self:_advance_review()
    end
end

-- move to the next hunk; at the last hunk, step to the next file (the second-tap of
-- s, and the seam that makes the review flow continuous across files)
function View:_advance_review()
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local target = nav.next_hunk(col.map, vim.api.nvim_win_get_cursor(win)[1])
    if target then
        vim.api.nvim_win_set_cursor(win, { target, 0 })
    else
        self:step_file("next", false) -- review flow: stop at the last file, don't wrap
    end
end

-- u: the mirror of s. unstage the staged hunk under the cursor, or retreat: a
-- second u moves to the previous hunk, and at the first hunk it steps to the
-- previous file landing on its last hunk, so repeated u walks the change set
-- backward, undoing hunk by hunk
function View:unstage_hunk()
    if not (self.can_stage and self.staging) then
        return vim.notify("dipher: hunk staging isn't available here", vim.log.levels.WARN)
    end
    local idx = self:_hunk_index_under_cursor()
    if idx and (self.staged_hunks[idx] or false) then
        self:_toggle_hunk(false)
    else
        self:_retreat_review()
    end
end

-- move to the previous hunk; at the first hunk, step to the previous file and land
-- on its last hunk (the backward seam, mirroring _advance_review's forward one)
function View:_retreat_review()
    local col = self:_focused_column()
    local win = col.winid or vim.api.nvim_get_current_win()
    local target = nav.prev_hunk(col.map, vim.api.nvim_win_get_cursor(win)[1])
    if target then
        vim.api.nvim_win_set_cursor(win, { target, 0 })
    else
        local before = self.model.path
        self:step_file("prev", false) -- review flow: stop at the first file, don't wrap
        if self.model.path ~= before then -- only when a previous file actually opened
            self:_focus_last_hunk()
        end
    end
end

-- toggle the staged state of the hunk under the cursor (§8.1), marking it in place
-- rather than re-reading: the diff stays put and the opposite key (u after s) keeps
-- working on it
---@param want_staged boolean
function View:_toggle_hunk(want_staged)
    if not (self.can_stage and self.staging) then
        return vim.notify("dipher: hunk staging isn't available here", vim.log.levels.WARN)
    end
    local idx = self:_hunk_index_under_cursor()
    if not idx then
        return vim.notify("dipher: no hunk under the cursor", vim.log.levels.WARN)
    end
    if (self.staged_hunks[idx] or false) == want_staged then
        return vim.notify("dipher: hunk already " .. (want_staged and "staged" or "unstaged"))
    end
    if self:_apply_hunk(idx, want_staged) then
        self.staging.refresh()
        self:_paint_staged()
    end
end

-- S: stage every hunk in the file, or, when they're all staged already (nothing left
-- to do), step to the next file, the file-level echo of s advancing past the last hunk
function View:stage_all()
    if not self:_toggle_all(true) and self.can_stage and self.staging then
        self:step_file("next", false) -- stop at the last file, don't wrap
    end
end

-- U: unstage every hunk, or, when none are staged (nothing to do), step back a file
-- landing on its last hunk, the file-level echo of u retreating past the first hunk
function View:unstage_all()
    if not self:_toggle_all(false) and self.can_stage and self.staging then
        local before = self.model.path
        self:step_file("prev", false) -- stop at the first file, don't wrap
        if self.model.path ~= before then -- only when a previous file actually opened
            self:_focus_last_hunk()
        end
    end
end

-- stage / unstage every hunk (§8.1). forward order keeps the running offset correct
-- as the index shifts under each apply; the panel refreshes once after the batch.
-- returns whether anything changed (false when already wholly in the target state),
-- so S/U can fall through to file stepping
---@param want_staged boolean
---@return boolean changed
function View:_toggle_all(want_staged)
    if not (self.can_stage and self.staging) then
        vim.notify("dipher: hunk staging isn't available here", vim.log.levels.WARN)
        return false
    end
    local changed = false
    for i = 1, #self.model.hunks do
        if self:_apply_hunk(i, want_staged) then
            changed = true
        end
    end
    if changed then
        self.staging.refresh()
        self:_paint_staged()
    end
    return changed
end

-- jump-to-file (§8.1, the `de` verb): leave the diff and open the real file on disk
-- at the line under the cursor, mapped to its new-side line (§6.2). the session lives
-- in its own tabpage (§8.6), so this ends it (dropping that tab) and opens the real
-- file back in the tab :Dipher was invoked from, where you'll keep working
function View:jump_to_file()
    local root = self.model.root
    if not root then
        vim.notify("dipher: jump-to-file needs a file-backed source", vim.log.levels.WARN)
        return
    end
    local abs = root .. "/" .. self.model.path
    if vim.fn.filereadable(abs) == 0 then
        -- e.g. a pure deletion: the new side has no file on disk to open
        vim.notify(("dipher: %s is not on disk"):format(self.model.path), vim.log.levels.WARN)
        return
    end

    local col = self:_focused_column()
    local win = (col.winid and vim.api.nvim_win_is_valid(col.winid)) and col.winid
        or vim.api.nvim_get_current_win()
    local target = nav.file_line(col.map, vim.api.nvim_win_get_cursor(win)[1])

    -- end the session: closing the panel/history tabcloses the dipher tab (via its
    -- on_close). then hop back to the invoking tab and open the real file there, so
    -- the diff tab doesn't linger. the owner carries the tab to return to
    local owner = require("dipher.panel").current() or require("dipher.history").current()
    local return_tab = owner and owner.return_tab
    if owner then
        owner:close()
    else
        self:close()
    end
    if return_tab and vim.api.nvim_tabpage_is_valid(return_tab) then
        vim.api.nvim_set_current_tabpage(return_tab)
    end
    vim.cmd.edit(vim.fn.fnameescape(abs))
    if target then
        pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
        vim.cmd("normal! zz")
    end
end

-- whether the new side is a live working-tree state (worktree or index), so the file
-- on disk is the editable target. excludes committed sources (rev↔rev, history, PR),
-- whose new side is a sha the worktree file doesn't correspond to
---@return boolean
function View:_editable_source()
    return self.model.new_rev == "WORKTREE" or self.model.new_rev == "INDEX"
end

-- edit-in-review (§8.1): pop the real working-tree file into a transient editable
-- window at the cursor's mapped new-side line, keeping the session. unlike
-- jump_to_file this never tears down the diff: you edit, `:w`, and the worktree
-- watcher re-sources the diff in place (cursor held near its hunk). the projection
-- buffer and line map are untouched (invariant 2); you edit the real file's own
-- buffer, so LSP / treesitter / undo all work natively. a staged diff (index↔ side)
-- can't be edited in place (you can't edit the index), so the file is unstaged first:
-- the staged change returns to the worktree and the watcher re-sources to the now-
-- unstaged diff, where the edit shows. git-correct; re-stage (s) when done
function View:edit_file()
    if not self:_editable_source() then
        return vim.notify(
            "dipher: editing applies to uncommitted (worktree/staged) changes only",
            vim.log.levels.WARN
        )
    end
    local root = self.model.root
    if not root then
        return vim.notify("dipher: editing needs a file-backed source", vim.log.levels.WARN)
    end
    local abs = root .. "/" .. self.model.path
    if vim.fn.filereadable(abs) == 0 then
        -- e.g. a pure deletion: no new-side file on disk to edit
        return vim.notify(
            ("dipher: %s is not on disk"):format(self.model.path),
            vim.log.levels.WARN
        )
    end

    local col = self:_focused_column()
    local win = (col.winid and vim.api.nvim_win_is_valid(col.winid)) and col.winid
        or vim.api.nvim_get_current_win()
    local target = nav.file_line(col.map, vim.api.nvim_win_get_cursor(win)[1]) -- §6.2

    -- staged diff: unstage the file and re-source to its unstaged index↔worktree view
    -- so the edit lands on a diff that reflects it. driven explicitly (the watcher's
    -- re-source is suppressed by the staging signature); falls back to an in-place
    -- unstage if no frontend hook is wired
    if self.model.new_rev == "INDEX" then
        if self.on_edit_unstage then
            self.on_edit_unstage(self.model.path)
        elseif self.can_stage and self.staging then
            self:_toggle_all(false)
        end
    end

    self:_open_edit_window(abs, target, col.winid)
end

-- open (or reuse) the edit window and load `abs` at `target`. split off the diff
-- window so the diff stays visible and live-updates beside the edit; a WinClosed
-- hook keeps `edit_win` in sync when the user closes it natively (`:q`)
---@param abs string
---@param target integer|nil
---@param anchor_win integer|nil  -- a diff window to split from
function View:_open_edit_window(abs, target, anchor_win)
    if self.edit_win and vim.api.nvim_win_is_valid(self.edit_win) then
        vim.api.nvim_set_current_win(self.edit_win)
    else
        -- split from the diff window, not the panel (`:Dipher edit` runs with the
        -- panel focused), so the new window lands beside the diff
        if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
            vim.api.nvim_set_current_win(anchor_win)
        end
        vim.cmd("rightbelow split")
        local win = vim.api.nvim_get_current_win()
        self.edit_win = win
        vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(win),
            once = true,
            callback = function()
                if self.edit_win == win then
                    self.edit_win = nil
                end
            end,
        })
    end
    vim.cmd.edit(vim.fn.fnameescape(abs))
    if target then
        pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
        vim.cmd("normal! zz")
    end
end

-- drop the edit window without losing work: a window holding unsaved edits is left
-- open (it's a normal file window, harmless to keep), otherwise it's closed. either
-- way `edit_win` is cleared. called on a file switch (stale window) and on teardown
function View:_release_edit_window()
    local win = self.edit_win
    self.edit_win = nil
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].modified then
        return -- keep the user's unsaved real-file window
    end
    pcall(vim.api.nvim_win_close, win, false)
end

-- the diff window is the session anchor: closing one of its columns ends the whole
-- session, so there's never a live state without a diff window. (re)arm a WinClosed
-- guard on each column window; re-armed after every relayout since winids change
function View:_arm_close_guard()
    armed_view = self -- this view now owns the close-teardown; supersede any prior one
    self._close_group =
        vim.api.nvim_create_augroup("dipher.viewclose." .. self.id, { clear = true })
    for _, col in ipairs(self.columns) do
        if col.winid and vim.api.nvim_win_is_valid(col.winid) then
            vim.api.nvim_create_autocmd("WinClosed", {
                group = self._close_group,
                pattern = tostring(col.winid),
                callback = function()
                    self:_on_diff_window_closed()
                end,
            })
        end
    end
end

-- a diff column window was closed. ignore our own programmatic closes (layout toggle,
-- teardown) and re-entrancy; otherwise tear down the whole session via its owner
-- (panel / history), or just this view when it's a bare diff. deferred because window
-- changes (closing the panel, the session tab) aren't allowed inside WinClosed
function View:_on_diff_window_closed()
    -- only the current session's view tears down (a recycled winid can fire a stale
    -- view's guard); ignore our own programmatic closes and re-entrancy
    if self ~= armed_view or self._suppress_close or self._closing then
        return
    end
    self._closing = true
    vim.schedule(function()
        -- re-check at run time: a newer session may have armed, or this view may have
        -- been torn down another way, between the close and this deferred callback
        if self ~= armed_view or #self.columns == 0 then
            return
        end
        local owner = require("dipher.panel").current() or require("dipher.history").current()
        if owner then
            owner:close() -- on_close cascades to this view + the session tab
        else
            self:close()
        end
    end)
end

-- lay the columns into windows. the first column anchors on its existing window
-- (or the current one on first open); extra columns reuse their window or vsplit
-- a fresh one; >1 column scroll-binds. single authority for open + layout toggle
function View:_relayout()
    local anchor = self.columns[1].winid
    if not (anchor and vim.api.nvim_win_is_valid(anchor)) then
        anchor = vim.api.nvim_get_current_win()
        self.columns[1].winid = anchor
    end
    self:_setup_window(anchor, self.columns[1].bufnr)
    vim.api.nvim_set_current_win(anchor)

    for i = 2, #self.columns do
        local col = self.columns[i]
        if not (col.winid and vim.api.nvim_win_is_valid(col.winid)) then
            vim.cmd("rightbelow vsplit")
            col.winid = vim.api.nvim_get_current_win()
        end
        self:_setup_window(col.winid, col.bufnr)
    end

    if #self.columns > 1 then
        for _, col in ipairs(self.columns) do
            set_wo(col.winid, "scrollbind", true)
        end
        vim.api.nvim_set_current_win(self.columns[1].winid)
        vim.cmd("syncbind")
    end
    self:_apply_folds() -- windows now exist; collapse the unchanged regions
    self:_paint_cursorline() -- windows now exist; show the cursor line over the bg
    self:_arm_close_guard() -- re-arm now the winids are current
end

-- open the view: stacked takes the current window, split adds a scroll-bound pane
---@return dipher.View
function View:open()
    self:_relayout()
    self:_focus_first_hunk() -- start on the first unstaged hunk, not line 1
    self:_paint_cursorline() -- repaint after the cursor moved off line 1
    return self
end

-- tear down a single column's window (if any) and buffer. `keep_win` spares that
-- window from closing (jump-to-file repurposes it for the real file), still
-- dropping the now-hidden synthetic buffer
---@param col dipher.ViewColumn|nil
---@param keep_win integer|nil
function View:_discard(col, keep_win)
    if not col then
        return
    end
    by_buf[col.bufnr] = nil
    statuscolumn.clear(col.bufnr)
    if col.winid and col.winid ~= keep_win and vim.api.nvim_win_is_valid(col.winid) then
        -- our own close: don't let the WinClosed guard mistake it for a user close
        self._suppress_close = true
        pcall(vim.api.nvim_win_close, col.winid, true)
        self._suppress_close = false
    end
    if vim.api.nvim_buf_is_valid(col.bufnr) then
        vim.api.nvim_buf_delete(col.bufnr, { force = true })
    end
end

-- close all windows and delete all buffers owned by the view. `keep_win` leaves
-- one window open (jump-to-file, which has already loaded the real file into it)
---@param keep_win integer|nil
function View:close(keep_win)
    self._closing = true -- block the WinClosed guard for the duration of teardown
    if armed_view == self then
        armed_view = nil
    end
    if self._close_group then
        pcall(vim.api.nvim_del_augroup_by_id, self._close_group)
        self._close_group = nil
    end
    self:_release_edit_window() -- drop any edit-in-review window (keeps it if unsaved)
    for _, col in ipairs(self.columns) do
        self:_discard(col, keep_win)
    end
    self.columns = {}
end

return View
