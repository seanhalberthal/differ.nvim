-- Shared region walk for renderers: visits unchanged regions (collapsing far
-- gaps to a separator) and hunks in document order, via callbacks. Pure Lua.
-- This is the single home for the vim.text.diff index convention so the subtle
-- off-by-one lives in exactly one place.

local M = {}

---@class dipher.WalkCallbacks
---@field context fun(o: integer, n: integer) -- one unchanged line (old lnum o, new lnum n)
---@field meta fun(hidden: integer)           -- a collapsed-context separator hiding `hidden` lines
---@field hunk fun(h: dipher.Hunk, hi: integer)

-- Drive the walk. `old_line_count` is #to_lines(old_text); `context` may be
-- math.huge for whole-file view. Callers handle the empty (no-hunk) case.
---@param model dipher.DiffModel
---@param context integer
---@param old_line_count integer
---@param cb dipher.WalkCallbacks
function M.walk(model, context, old_line_count, cb)
    -- Emit an unchanged region [old_from..] / [new_from..] of length `len`,
    -- keeping `lead` context lines at the start and `tail` at the end (0 at a
    -- file boundary) and collapsing the middle to a separator when it exceeds them.
    local function emit_gap(old_from, new_from, len, has_prev, has_next)
        if len <= 0 then
            return
        end
        local lead = math.min(has_prev and context or 0, len)
        local tail = math.min(has_next and context or 0, len)
        if lead + tail >= len then
            for k = 0, len - 1 do
                cb.context(old_from + k, new_from + k)
            end
            return
        end
        for k = 0, lead - 1 do
            cb.context(old_from + k, new_from + k)
        end
        cb.meta(len - lead - tail)
        for k = len - tail, len - 1 do
            cb.context(old_from + k, new_from + k)
        end
    end

    local cursor_old, cursor_new = 1, 1
    for hi, h in ipairs(model.hunks) do
        -- vim.text.diff reports pure insertions as old_count==0 with old_start at
        -- the preceding old line (deletions mirror it on the new side), so derive
        -- the last unchanged line before the hunk from the count, not the start.
        local gap_old_end = h.old_count > 0 and (h.old_start - 1) or h.old_start
        emit_gap(cursor_old, cursor_new, gap_old_end - cursor_old + 1, hi > 1, true)
        cb.hunk(h, hi)
        cursor_old = h.old_count > 0 and (h.old_start + h.old_count) or (h.old_start + 1)
        cursor_new = h.new_count > 0 and (h.new_start + h.new_count) or (h.new_start + 1)
    end
    emit_gap(cursor_old, cursor_new, old_line_count - cursor_old + 1, true, false)
end

return M
