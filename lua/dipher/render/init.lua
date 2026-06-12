-- Render dispatch: the frozen signature is render(model, opts) -> RenderResult.
-- Renderers are pure functions over the hunk model; a layout toggle is a re-render.
--
-- A render is N index-aligned columns, each its own buffer content + LineMap:
-- stacked is one "unified" column (old/new interleaved, dual-rail gutter), split
-- is two columns ("old" left, "new" right) with filler keeping rows aligned. The
-- view layer creates one buffer per column and scroll-binds when N > 1.

---@alias dipher.ColumnSide "old"|"new"|"unified"

---@class dipher.Column
---@field lines string[]        -- this column's buffer content (filler rows = "")
---@field map dipher.LineMap    -- this column's line map
---@field side dipher.ColumnSide

---@class dipher.RenderResult
---@field columns dipher.Column[] -- one per buffer; all share `rows`
---@field rows integer            -- aligned row count

---@alias dipher.Layout "stacked"|"split"

---@alias dipher.Renderer fun(model: dipher.DiffModel, opts: table): dipher.RenderResult

local M = {}

---@type table<dipher.Layout, string>
local RENDERERS = {
    stacked = "dipher.render.stacked",
    split = "dipher.render.split",
}

-- Render a model under the given layout
---@param model dipher.DiffModel
---@param opts { layout: dipher.Layout, context: integer, deep_diff: table }
---@return dipher.RenderResult
function M.render(model, opts)
    local mod = RENDERERS[opts.layout]
    if not mod then
        error(("dipher: unknown layout %q"):format(tostring(opts.layout)))
    end
    ---@type dipher.Renderer
    local renderer = require(mod).render
    return renderer(model, opts)
end

return M
