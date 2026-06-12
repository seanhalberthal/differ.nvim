-- Hunk navigation: pure scans over a LineMap for the next/prev hunk boundary.
-- No Neovim API, so the motion logic is unit-testable; the View binds these to
-- ]c / [c and moves the cursor.

local M = {}

-- Buffer lnums (1-based) that begin a hunk block — the first line whose `hunk`
-- index differs from the line above it. Ascending.
---@param map dipher.LineMap
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

-- First hunk start strictly after `lnum`, or nil if cursor is in/after the last
-- hunk. Does not wrap (matches Vim diff-mode ]c).
---@param map dipher.LineMap
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

-- Last hunk start strictly before `lnum`, or nil if cursor is in/before the
-- first hunk. Does not wrap.
---@param map dipher.LineMap
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

return M
