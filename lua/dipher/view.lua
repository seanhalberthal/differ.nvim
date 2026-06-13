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

local ns = vim.api.nvim_create_namespace("dipher")
local STATUSCOLUMN_EXPR = '%!v:lua.require("dipher.ui.statuscolumn").render()'
local FOLDTEXT_EXPR = 'v:lua.require("dipher.ui.foldtext").render()'
local CTRL_D = vim.api.nvim_replace_termcodes("<C-d>", true, false, true)
local CTRL_U = vim.api.nvim_replace_termcodes("<C-u>", true, false, true)

---@type table<integer, dipher.View> -- bufnr -> owning view, for command dispatch
local by_buf = {}

---@class dipher.ViewColumn
---@field bufnr integer
---@field winid integer|nil
---@field map dipher.LineMap
---@field side dipher.ColumnSide

---@class dipher.View
---@field columns dipher.ViewColumn[]
---@field model dipher.DiffModel
---@field layout dipher.Layout
---@field context integer
---@field deep_diff table
---@field keymaps table
local View = {}
View.__index = View

-- build a view for a model. buffers and data are created here; windows are not
-- touched until :open(), so a View can be constructed headlessly for tests
---@param model dipher.DiffModel
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table, keymaps?: table }
---@return dipher.View
function View.new(model, opts)
    local self = setmetatable({
        columns = {},
        model = model,
        layout = opts.layout,
        context = opts.context,
        deep_diff = opts.deep_diff,
        keymaps = opts.keymaps or {},
    }, View)
    self:rerender(opts)
    return self
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
    self:_apply_folds() -- no-op until windows exist (open / relayout re-apply)
end

-- (re)create the native folds for each column's window from its fold ranges, then
-- close them (collapsed by default). re-run on every render so a context change
-- (d= / d- / :Dipher context) just re-folds without touching buffer content. with
-- context = full the renderer returns no ranges, so everything is left open.
function View:_apply_folds()
    for _, col in ipairs(self.columns) do
        local win = col.winid
        if win and vim.api.nvim_win_is_valid(win) then
            vim.wo[win].foldmethod = "manual"
            vim.wo[win].foldtext = FOLDTEXT_EXPR
            vim.wo[win].foldenable = true
            vim.wo[win].foldlevel = 0 -- collapsed by default
            vim.api.nvim_win_call(win, function()
                vim.cmd("silent! normal! zE") -- drop existing folds before rebuilding
                for _, f in ipairs(col.folds or {}) do
                    if f.last > f.first then
                        vim.cmd(("silent! %d,%dfold"):format(f.first, f.last))
                    end
                end
            end)
        end
    end
end

-- the view owning the current buffer, if any. commands dispatch through this
---@return dipher.View|nil
function View.current()
    return by_buf[vim.api.nvim_get_current_buf()]
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
-- so it never changes here, no relayout
---@param model dipher.DiffModel
function View:set_source(model)
    self.model = model
    self:rerender({ layout = self.layout, context = self.context, deep_diff = self.deep_diff })
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
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].wrap = false
    vim.wo[winid].scrollbind = false -- cleared default; split re-enables it in :open
    vim.wo[winid].statuscolumn = STATUSCOLUMN_EXPR
    vim.keymap.set("n", "]c", function()
        self:goto_hunk("next")
    end, { buffer = bufnr, desc = "dipher: next hunk" })
    vim.keymap.set("n", "[c", function()
        self:goto_hunk("prev")
    end, { buffer = bufnr, desc = "dipher: previous hunk" })
    vim.keymap.set("n", "d=", function()
        self:adjust_context(1)
    end, { buffer = bufnr, desc = "dipher: more context" })
    vim.keymap.set("n", "d-", function()
        self:adjust_context(-1)
    end, { buffer = bufnr, desc = "dipher: less context" })
    -- ]f / [f drive the file panel's selection in lockstep, keeping focus here in
    -- the diff window (no-op when no panel is open)
    vim.keymap.set("n", "]f", function()
        self:step_file("next")
    end, { buffer = bufnr, desc = "dipher: next file" })
    vim.keymap.set("n", "[f", function()
        self:step_file("prev")
    end, { buffer = bufnr, desc = "dipher: previous file" })
    -- f / b quarter-page scroll (opt-out: shadows native find-char / back-word)
    if self.keymaps.quarter_scroll ~= false then
        vim.keymap.set("n", "f", function()
            self:quarter_scroll("down")
        end, { buffer = bufnr, desc = "dipher: scroll down a quarter page" })
        vim.keymap.set("n", "b", function()
            self:quarter_scroll("up")
        end, { buffer = bufnr, desc = "dipher: scroll up a quarter page" })
    end
end

-- step the file panel's selection (and re-source this view) without leaving the
-- diff window, the in-view counterpart to the panel's own ]f / [f
---@param direction "next"|"prev"
function View:step_file(direction)
    local panel = require("dipher.panel").current()
    if panel and panel:is_open() then
        panel:goto_file(direction, true) -- keep focus in the diff window
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
    end
end

-- jump-to-file (§8.1, the `de` verb): leave the diff and open the real file on
-- disk at the line under the cursor, mapped to its new-side line (§6.2). the
-- focused diff window is reused for the file and survives; the rest of the
-- session (panel, other columns, synthetic buffers) is torn down around it
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

    -- load the real file into the focused window, which survives the teardown
    vim.api.nvim_set_current_win(win)
    vim.cmd.edit(vim.fn.fnameescape(abs))
    if target then
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
        vim.cmd("normal! zz")
    end

    -- end the session. the panel drives this view, so drop its on_close (which
    -- would re-close `win`) before tearing it down, then discard our own buffers
    -- and windows while sparing the one now holding the real file
    local panel = require("dipher.panel").current()
    if panel then
        panel.on_close = nil
        panel:close()
    end
    self:close(win)
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
            vim.wo[col.winid].scrollbind = true
        end
        vim.api.nvim_set_current_win(self.columns[1].winid)
        vim.cmd("syncbind")
    end
    self:_apply_folds() -- windows now exist; collapse the unchanged regions
end

-- open the view: stacked takes the current window, split adds a scroll-bound pane
---@return dipher.View
function View:open()
    self:_relayout()
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
        pcall(vim.api.nvim_win_close, col.winid, true)
    end
    if vim.api.nvim_buf_is_valid(col.bufnr) then
        vim.api.nvim_buf_delete(col.bufnr, { force = true })
    end
end

-- close all windows and delete all buffers owned by the view. `keep_win` leaves
-- one window open (jump-to-file, which has already loaded the real file into it)
---@param keep_win integer|nil
function View:close(keep_win)
    for _, col in ipairs(self.columns) do
        self:_discard(col, keep_win)
    end
    self.columns = {}
end

return View
