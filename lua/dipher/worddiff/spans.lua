-- Fragment diff: paired lines -> changed byte-col spans, no Neovim API
-- TODO: tokenize each pair, diff token streams, map changed ranges to SubSpans

local M = {}

---@class dipher.PairSpans
---@field old dipher.SubSpan[]
---@field new dipher.SubSpan[]

-- Emit word-level spans for a single old/new line pair
---@param old_line string
---@param new_line string
---@param mode "word"|"char"
---@return dipher.PairSpans
function M.emit(old_line, new_line, mode)
    -- TODO: run vim.diff() (or a pure LCS) over token streams and project
    -- changed token ranges back to byte columns
    return { old = {}, new = {} }
end

return M
