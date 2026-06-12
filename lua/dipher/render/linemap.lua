-- Line map: the frozen contract everything reads
-- Pure Lua, no Neovim API, so renderers that produce maps stay golden-testable

---@class dipher.SubSpan
---@field col_start integer  -- byte col, 0-based inclusive
---@field col_end integer    -- byte col, 0-based exclusive

---@alias dipher.RailKind "context"|"old"|"new"|"meta"

---@class dipher.RailLine
---@field kind dipher.RailKind
---@field old integer|nil
---@field new integer|nil
---@field hunk integer|nil           -- index into DiffModel.hunks
---@field spans dipher.SubSpan[]|nil -- word-level changed regions (old/new only)

---@class dipher.LineMap
---@field lines dipher.RailLine[]          -- indexed by buffer lnum (1-based)
---@field from_old table<integer, integer> -- old lnum -> buffer lnum
---@field from_new table<integer, integer> -- new lnum -> buffer lnum
local LineMap = {}
LineMap.__index = LineMap

-- Create an empty map for a renderer to populate
---@return dipher.LineMap
function LineMap.new()
    return setmetatable({ lines = {}, from_old = {}, from_new = {} }, LineMap)
end

-- Append a rail line and keep the reverse indices in sync
---@param line dipher.RailLine
---@return integer buf_lnum
function LineMap:push(line)
    local lnum = #self.lines + 1
    self.lines[lnum] = line
    if line.old and (line.kind == "old" or line.kind == "context") then
        self.from_old[line.old] = lnum
    end
    if line.new and (line.kind == "new" or line.kind == "context") then
        self.from_new[line.new] = lnum
    end
    return lnum
end

-- Number of derived-buffer lines
---@return integer
function LineMap:len()
    return #self.lines
end

return LineMap
