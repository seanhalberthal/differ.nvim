-- Dual-rail gutter: a statuscolumn function reading the active buffer's line map
-- Map lookup is O(1); rail strings are pre-formatted at render time

local M = {}

---@type table<integer, string[]> -- bufnr -> pre-formatted rail string per lnum
local rails = {}

-- Store pre-formatted rail strings for a buffer after a render
---@param bufnr integer
---@param strings string[]
function M.set(bufnr, strings)
    rails[bufnr] = strings
end

-- Drop a buffer's cached rail strings
---@param bufnr integer
function M.clear(bufnr)
    rails[bufnr] = nil
end

-- statuscolumn callback: return the rail string for the current line
---@return string
function M.render()
    -- TODO: index rails[bufnr] by v:lnum once renderers populate the cache
    local buf = vim.g.statusline_winid and vim.api.nvim_win_get_buf(vim.g.statusline_winid)
    local cache = buf and rails[buf]
    if not cache then
        return ""
    end
    return cache[vim.v.lnum] or ""
end

return M
