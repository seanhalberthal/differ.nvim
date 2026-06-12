-- Buffer lifecycle: own one derived buffer per render column, apply render output,
-- hold each column's map. Buffers + maps are regenerated atomically; overlays are
-- extmark-only. A render is N aligned columns (stacked: 1 unified; split: old/new).

---@class dipher.ViewColumn
---@field bufnr integer
---@field map dipher.LineMap
---@field side dipher.ColumnSide

---@class dipher.View
---@field columns dipher.ViewColumn[]
---@field model dipher.DiffModel
---@field layout dipher.Layout
---@field context integer
local View = {}
View.__index = View

local render = require("dipher.render")

-- Create a view for a model; buffers are allocated lazily to match the render's
-- column count on first render.
---@param model dipher.DiffModel
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
---@return dipher.View
function View.new(model, opts)
    local self = setmetatable({
        columns = {},
        model = model,
        layout = opts.layout,
        context = opts.context,
    }, View)
    self:rerender(opts)
    return self
end

-- The map of the column for a side, or the unified map. Consumers (]c, staging,
-- comment anchoring) read this rather than branching on layout themselves.
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

-- Re-render the active model and atomically replace each column's content and map.
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
function View:rerender(opts)
    self.layout = opts.layout
    self.context = opts.context
    local result = render.render(self.model, opts)

    for i, col in ipairs(result.columns) do
        local existing = self.columns[i]
        local bufnr = existing and existing.bufnr or vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, col.lines)
        vim.bo[bufnr].modifiable = false
        self.columns[i] = { bufnr = bufnr, map = col.map, side = col.side }
    end
    -- A layout toggle can change column count (1 <-> 2); drop stale buffers.
    for i = #result.columns + 1, #self.columns do
        local stale = self.columns[i]
        if stale and vim.api.nvim_buf_is_valid(stale.bufnr) then
            vim.api.nvim_buf_delete(stale.bufnr, { force = true })
        end
        self.columns[i] = nil
    end
    -- TODO: lay columns into windows (scrollbind when >1), apply word-level +
    -- thread extmark layers, wire the statuscolumn rail cache from each map.
end

return View
