-- Stacked dual-rail renderer: old/new interleaved per hunk on one scroll surface
-- Pure function over the hunk model, so it stays golden-testable

local LineMap = require("dipher.render.linemap")

local M = {}

-- Render a model into interleaved buffer lines plus a populated line map
---@param model dipher.DiffModel
---@param opts { context: integer }
---@return dipher.RenderResult
function M.render(model, opts)
    -- TODO: walk hunks, emit context/old/new rail lines, slice context from
    -- old_text/new_text by `opts.context`, attach word-level spans from pairs
    local map = LineMap.new()
    local lines = {}
    return { lines = lines, map = map }
end

return M
