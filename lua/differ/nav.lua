-- hunk navigation: pure scans over a LineMap for the next/prev hunk boundary.
-- no nvim API, so the motion logic is unit-testable; the View binds these to
-- ]c / [c and moves the cursor

local M = {}

-- buffer lnums (1-based) that begin a hunk block, the first line whose `hunk`
-- index differs from the line above it. ascending
---@param map differ.LineMap
---@return integer[]
local function hunk_starts(map)
    local starts = {}
    local prev = nil
    for i, line in ipairs(map.lines) do
        if line.hunk and line.hunk ~= prev then
            starts[#starts + 1] = i
        end
        prev = line.hunk
    end
    return starts
end

-- first hunk start strictly after `lnum`, or nil if cursor is in/after the last
-- hunk. does not wrap (matches vim diff-mode ]c)
---@param map differ.LineMap
---@param lnum integer
---@return integer|nil
function M.next_hunk(map, lnum)
    for _, s in ipairs(hunk_starts(map)) do
        if s > lnum then
            return s
        end
    end
    return nil
end

-- last hunk start strictly before `lnum`, or nil if cursor is in/before the
-- first hunk. does not wrap
---@param map differ.LineMap
---@param lnum integer
---@return integer|nil
function M.prev_hunk(map, lnum)
    local best = nil
    for _, s in ipairs(hunk_starts(map)) do
        if s < lnum then
            best = s
        else
            break
        end
    end
    return best
end

-- the real-file (new-side) line for jump-to-file: the cursor line's own
-- `new` if it has one, else the nearest following line's `new` (a deleted/meta
-- line maps forward to the next live new line), else the nearest preceding new
-- (cursor sitting past the last new line). nil when the map has no new side at
-- all, e.g. a pure deletion
---@param map differ.LineMap
---@param lnum integer
---@return integer|nil
function M.file_line(map, lnum)
    local line = map.lines[lnum]
    if line and line.new then
        return line.new
    end
    for i = lnum + 1, #map.lines do
        if map.lines[i].new then
            return map.lines[i].new
        end
    end
    for i = lnum - 1, 1, -1 do
        if map.lines[i].new then
            return map.lines[i].new
        end
    end
    return nil
end

return M
