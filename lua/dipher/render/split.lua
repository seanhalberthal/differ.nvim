-- Side-by-side renderer from the same hunk model and map contract as stacked
-- Pure function over the hunk model

local LineMap = require("dipher.render.linemap")

local M = {}

-- Render a model into side-by-side buffer lines plus a populated line map
---@param model dipher.DiffModel
---@param opts { context: integer }
---@return dipher.RenderResult
function M.render(model, opts)
    -- TODO: emit aligned old/new columns with filler for unbalanced hunks
    local map = LineMap.new()
    local lines = {}
    return { lines = lines, map = map }
end

return M
