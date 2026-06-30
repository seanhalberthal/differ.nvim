-- lualine integration. differ's diff buffers carry a private `differdiff`
-- filetype so foreign `FileType <lang>` consumers (lsp, lint, semantic tokens)
-- don't attach to a throwaway differ:// buffer; the source filetype is stashed in
-- b:differ_filetype. lualine's stock `filetype` component reads &filetype and would
-- show "differdiff", so this exposes a drop-in that surfaces the source filetype
-- (with its devicon) on differ buffers and behaves like the stock component elsewhere.
--
-- require the submodule directly so it stays lazy-load safe:
--   lualine_x = { require("differ.lualine").filetype }
-- referencing it through require("differ") would pull in the whole plugin at startup

local M = {}

-- a colored devicon for `ft` as a statusline-ready "%#hl#icon%* " fragment, or ""
-- when nvim-web-devicons is absent or yields no glyph
---@param ft string
---@return string
local function devicon(ft)
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if not ok then
        return ""
    end
    local icon, hl = devicons.get_icon_by_filetype(ft, { default = true })
    if not icon then
        return ""
    end
    if hl then
        return ("%%#%s#%s%%* "):format(hl, icon)
    end
    return icon .. " "
end

-- the source filetype on a differ buffer, else the buffer's own &filetype. reads the
-- current buffer, which lualine makes the drawn window's buffer during component eval
---@return string
local function resolve()
    local stashed = vim.b.differ_filetype
    if type(stashed) == "string" and stashed ~= "" then
        return stashed
    end
    return vim.bo.filetype
end

-- drop-in for lualine's `filetype` component: shows the source filetype (icon +
-- name) on differ buffers, the native filetype everywhere else
---@return string
function M.filetype()
    local ft = resolve()
    if ft == "" then
        return ""
    end
    return devicon(ft) .. ft
end

return M
