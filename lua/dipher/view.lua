-- Buffer lifecycle: own the derived buffer, apply render output, hold the map
-- Buffer + map are regenerated atomically; overlays are extmark-only

---@class dipher.View
---@field bufnr integer
---@field model dipher.DiffModel
---@field map dipher.LineMap
---@field layout dipher.Layout
---@field context integer
local View = {}
View.__index = View

local render = require("dipher.render")

-- Create a scratch buffer-backed view for a model
---@param model dipher.DiffModel
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
---@return dipher.View
function View.new(model, opts)
    local self = setmetatable({
        bufnr = vim.api.nvim_create_buf(false, true),
        model = model,
        layout = opts.layout,
        context = opts.context,
    }, View)
    self:rerender(opts)
    return self
end

-- Re-render the active model and atomically replace buffer content and map
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
function View:rerender(opts)
    self.layout = opts.layout
    self.context = opts.context
    local result = render.render(self.model, opts)
    self.map = result.map
    vim.bo[self.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, result.lines)
    vim.bo[self.bufnr].modifiable = false
    -- TODO: apply word-level + thread extmark layers, wire statuscolumn cache
end

return View
