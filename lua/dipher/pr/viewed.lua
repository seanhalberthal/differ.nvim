-- pure helpers for the pr viewed-state nav (§8.2): the unviewed scan and the
-- entry->index lookup. kept vim-free so the direction / no-wrap decision is unit-
-- tested under busted. a file is "viewed" when entry.viewed is truthy (map_files
-- already collapses VIEWED and DISMISSED to that boolean)

local M = {}

-- the index of `entry` in `entries` by identity, or nil
---@param entries dipher.FileEntry[]
---@param entry dipher.FileEntry|nil
---@return integer|nil
function M.index_of(entries, entry)
    if not entry then
        return nil
    end
    for i, e in ipairs(entries) do
        if e == entry then
            return i
        end
    end
    return nil
end

-- the nearest unviewed file from `from` in `direction`, or nil when none remain.
-- no wrap: stop at the ends so "no more unviewed" stays visible. `from` is the
-- current 1-based index (0 to scan the whole list forward from the start)
---@param entries dipher.FileEntry[]
---@param from integer  -- current index; 0 means "before the first"
---@param direction "next"|"prev"
---@return integer|nil
function M.next_unviewed(entries, from, direction)
    local step = direction == "prev" and -1 or 1
    local i = from + step
    while i >= 1 and i <= #entries do
        if not entries[i].viewed then
            return i
        end
        i = i + step
    end
    return nil
end

return M
