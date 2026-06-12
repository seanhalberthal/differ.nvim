-- Syntax projection: map source-coordinate treesitter captures onto derived-buffer
-- rows through a line map's from-index. Pure Lua, no Neovim API — this is the
-- §6.5 "captures + map -> extmark list" step, the unit-testable core of the pass.
-- Columns are byte-identical to the source line, so byte cols pass through
-- unchanged; only the row is remapped. Captures on a source line not present in
-- this column (meta/filler/no-partner) have no buffer row and are dropped.

local M = {}

---@class dipher.SyntaxCapture
---@field row integer       -- 0-based source line
---@field col_start integer -- byte col, 0-based inclusive
---@field col_end integer   -- byte col, 0-based exclusive
---@field hl string         -- resolved highlight group

---@class dipher.SyntaxMark
---@field row integer       -- 0-based buffer row
---@field col_start integer
---@field col_end integer
---@field hl string

-- Project source captures onto buffer rows via `from_map` (source lnum 1-based ->
-- buffer lnum 1-based). Returns extmark specs in buffer coordinates.
---@param captures dipher.SyntaxCapture[]
---@param from_map table<integer, integer>
---@return dipher.SyntaxMark[]
function M.project(captures, from_map)
    local out = {}
    for _, c in ipairs(captures) do
        local buf_lnum = from_map[c.row + 1]
        if buf_lnum then
            out[#out + 1] = {
                row = buf_lnum - 1,
                col_start = c.col_start,
                col_end = c.col_end,
                hl = c.hl,
            }
        end
    end
    return out
end

return M
