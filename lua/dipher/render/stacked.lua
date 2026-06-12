-- Stacked dual-rail renderer: old/new interleaved per hunk on one scroll surface.
-- Pure function over the hunk model (no Neovim API) so it stays golden-testable.
-- Buffer lines are raw code (search/yank/motions work); +/- styling and line
-- numbers are painted later from the map, never baked into the text.

local LineMap = require("dipher.render.linemap")
local text_util = require("dipher.util.text")
local spans = require("dipher.worddiff.spans")
local walk = require("dipher.render.walk")

local M = {}

-- Buffer text for a collapsed-context separator. No line numbers (kind=="meta").
---@param hidden integer
---@return string
local function meta_text(hidden)
    return ("\u{22ef} %d unchanged line%s"):format(hidden, hidden == 1 and "" or "s")
end

-- Render a model into interleaved buffer lines plus a populated line map.
---@param model dipher.DiffModel
---@param opts { context: integer, deep_diff?: table }
---@return dipher.RenderResult
function M.render(model, opts)
    local map = LineMap.new()
    local lines = {}

    -- Identical content produces no hunks; nothing to show.
    if #model.hunks == 0 then
        return { lines = lines, map = map }
    end

    local context = opts.context or 3
    local deep = opts.deep_diff or {}
    local deep_on = deep.enabled ~= false
    local threshold = deep.similarity_threshold or 0.5
    local mode = deep.granularity or "word"

    -- Context lines are identical on both sides, so old_all supplies their text.
    local old_all = text_util.to_lines(model.old_text)

    walk.walk(model, context, #old_all, {
        context = function(o, n)
            lines[#lines + 1] = old_all[o]
            map:push({ kind = "context", old = o, new = n })
        end,
        meta = function(hidden)
            lines[#lines + 1] = meta_text(hidden)
            map:push({ kind = "meta" })
        end,
        -- A hunk shows its old (deleted) lines as a block, then its new (added) lines.
        hunk = function(h, hi)
            local old_spans, new_spans = {}, {}
            if deep_on then
                old_spans, new_spans = spans.for_hunk(h, threshold, mode)
            end
            for k = 1, h.old_count do
                lines[#lines + 1] = h.old_lines[k]
                map:push({
                    kind = "old",
                    old = h.old_start + k - 1,
                    hunk = hi,
                    spans = old_spans[k],
                })
            end
            for k = 1, h.new_count do
                lines[#lines + 1] = h.new_lines[k]
                map:push({
                    kind = "new",
                    new = h.new_start + k - 1,
                    hunk = hi,
                    spans = new_spans[k],
                })
            end
        end,
    })

    return { lines = lines, map = map }
end

return M
