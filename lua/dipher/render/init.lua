-- Render dispatch: the frozen signature is render(model, opts) -> { lines, map }
-- Renderers are pure functions over the hunk model; a layout toggle is a re-render

---@class dipher.RenderResult
---@field lines string[]        -- derived-buffer content
---@field map dipher.LineMap

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
