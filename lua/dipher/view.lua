-- View lifecycle: own one derived buffer per render column, lay them into windows
-- (one for stacked, a scroll-bound pair for split), and hold each column's map.
-- Buffers + maps are regenerated atomically on re-render; the gutter rail and the
-- highlight layer are refreshed from the map; overlays are extmark-only.

local render = require("dipher.render")
local paint = require("dipher.ui.paint")
local statuscolumn = require("dipher.ui.statuscolumn")
local nav = require("dipher.nav")

local ns = vim.api.nvim_create_namespace("dipher")
local STATUSCOLUMN_EXPR = '%!v:lua.require("dipher.ui.statuscolumn").render()'

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
local View = {}
View.__index = View

-- Build a view for a model. Buffers and data are created here; windows are not
-- touched until :open(), so a View can be constructed headlessly for tests.
---@param model dipher.DiffModel
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
---@return dipher.View
function View.new(model, opts)
    local self = setmetatable({
        columns = {},
        model = model,
        layout = opts.layout,
        context = opts.context,
        deep_diff = opts.deep_diff,
    }, View)
    self:rerender(opts)
    return self
end

-- The map for a side, or the unified map. Consumers (]c, staging, comment
-- anchoring) read this rather than branching on layout themselves.
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

-- Re-render the active model and atomically replace each column's content, map,
-- gutter rail, and highlight layer. Window layout is unchanged; if a re-render
-- changes the column count (a layout toggle), call :open() to relayout.
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
function View:rerender(opts)
    self.layout = opts.layout
    self.context = opts.context
    self.deep_diff = opts.deep_diff
    local result = render.render(self.model, opts)

    for i, col in ipairs(result.columns) do
        local existing = self.columns[i]
        local bufnr = existing and existing.bufnr or vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, col.lines)
        vim.bo[bufnr].modifiable = false
        paint.apply(bufnr, ns, col)
        statuscolumn.set(bufnr, statuscolumn.format(col))
        self.columns[i] = {
            bufnr = bufnr,
            winid = existing and existing.winid or nil,
            map = col.map,
            side = col.side,
        }
    end
    -- Shrinking column count (split -> stacked): drop the surplus buffers/windows.
    for i = #result.columns + 1, #self.columns do
        self:_discard(self.columns[i])
        self.columns[i] = nil
    end
end

-- Per-window appearance + buffer-local motions. Our own dual-rail gutter replaces
-- the native gutter; ]c / [c jump between hunks via the active column's map.
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
end

-- Move the cursor to the next/prev hunk in the focused column. No-op (silent) at
-- the first/last hunk, matching Vim diff-mode motions.
---@param direction "next"|"prev"
function View:goto_hunk(direction)
    local win = vim.api.nvim_get_current_win()
    local col = self.columns[1]
    for _, c in ipairs(self.columns) do
        if c.winid == win then
            col = c
            break
        end
    end
    local lnum = vim.api.nvim_win_get_cursor(col.winid or win)[1]
    -- Explicit branch, not `a and next() or prev()`: next_hunk returns nil at the
    -- last hunk, which the and/or idiom would wrongly fall through to prev_hunk.
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

-- Lay the columns into windows from the current window outward. Stacked takes the
-- current window; split makes it the left (old) column and vsplits a scroll-bound
-- right (new) column.
---@return dipher.View
function View:open()
    local base = vim.api.nvim_get_current_win()
    self.columns[1].winid = base
    self:_setup_window(base, self.columns[1].bufnr)

    if #self.columns > 1 then
        vim.cmd("rightbelow vsplit")
        local right = vim.api.nvim_get_current_win()
        self.columns[2].winid = right
        self:_setup_window(right, self.columns[2].bufnr)
        for _, col in ipairs(self.columns) do
            vim.wo[col.winid].scrollbind = true
        end
        vim.api.nvim_set_current_win(base)
        vim.cmd("syncbind")
    end
    return self
end

-- Tear down a single column's window (if any) and buffer.
---@param col dipher.ViewColumn|nil
function View:_discard(col)
    if not col then
        return
    end
    statuscolumn.clear(col.bufnr)
    if col.winid and vim.api.nvim_win_is_valid(col.winid) then
        pcall(vim.api.nvim_win_close, col.winid, true)
    end
    if vim.api.nvim_buf_is_valid(col.bufnr) then
        vim.api.nvim_buf_delete(col.bufnr, { force = true })
    end
end

-- Close all windows and delete all buffers owned by the view.
function View:close()
    for _, col in ipairs(self.columns) do
        self:_discard(col)
    end
    self.columns = {}
end

return View
