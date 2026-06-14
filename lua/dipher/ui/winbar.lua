-- winbar widgets: the diff window's hunk counter and the file panel's progress
-- meter. both are `%!` winbar expressions, so they redraw on cursor move with no
-- autocmds; each reads g:statusline_winid (set during winbar eval) to find its window

local M = {}

-- escape statusline-special percent signs in interpolated text (a path can hold one)
---@param s string
---@return string
local function esc(s)
    return (s:gsub("%%", "%%%%"))
end

-- the 1-based hunk the cursor sits in or just past: the count of hunk blocks
-- starting at or before `lnum`, so a trailing-context line still reads as its hunk
---@param map dipher.LineMap
---@param lnum integer
---@return integer
local function hunk_at(map, lnum)
    local k, prev = 0, nil
    for i = 1, math.min(lnum, #map.lines) do
        local h = map.lines[i].hunk
        if h and h ~= prev then
            k = k + 1
        end
        prev = h
    end
    return k
end

-- diff-window winbar: "<file>  ◆ hunk K/N", file on the left, the hunk count
-- right-aligned. empty when the drawn window isn't a dipher diff
---@return string
function M.diff()
    local win = vim.g.statusline_winid
    if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
        return ""
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local view = require("dipher.view").for_buf(buf)
    if not view then
        return ""
    end
    local map
    for _, c in ipairs(view.columns) do
        if c.bufnr == buf then
            map = c.map
            break
        end
    end
    if not map then
        return ""
    end
    local total = #view.model.hunks
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local k = math.max(hunk_at(map, lnum), total > 0 and 1 or 0)
    return (" %s %%=◆ hunk %d/%d "):format(
        esc(vim.fn.fnamemodify(view.model.path, ":t")),
        k,
        total
    )
end

-- panel winbar: a bar plus "file K/N" for the cursor's position in the file list
---@return string
function M.panel()
    local win = vim.g.statusline_winid
    if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
        return ""
    end
    local panel = require("dipher.panel").current()
    if not (panel and panel.winid == win) then
        return ""
    end
    -- total = every file in the change set (fold-independent), not just the rows
    -- currently visible; idx = the fold-independent number of the file at/before the
    -- cursor, so the meter stays accurate when dirs are collapsed
    local total = panel.file_total or 0
    if total == 0 then
        return ""
    end
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    local idx
    for i = math.min(cur, #panel.meta), 1, -1 do
        local m = panel.meta[i]
        if m and m.kind == "file" then
            idx = m.file_index
            break
        end
    end
    idx = math.max(idx or 1, 1)
    local width = 12
    local filled = math.floor(width * idx / total + 0.5)
    local bar = string.rep("█", filled) .. string.rep("░", width - filled)
    return (" ▕%s▏ file %d/%d "):format(bar, idx, total)
end

return M
