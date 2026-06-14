-- highlight group definitions for diff lines, word-level spans, threads, and the
-- file panel. structural groups are plain links; the panel's status + count groups
-- carry a semantic palette (green add / yellow modify / blue rename / orange
-- conflict / red delete) derived from the active theme with hex fallbacks, mirroring
-- the user's diffview/octo colours. all are set with `default = true` so explicit
-- user overrides win, and re-applied on `ColorScheme` so theme switches propagate

local M = {}

-- static links: body diff layers and structural panel chrome
---@type table<string, vim.api.keyset.highlight>
local LINKS = {
    dipherLineDelete = { link = "DiffDelete" },
    dipherLineAdd = { link = "DiffAdd" },
    dipherWordDelete = { link = "DiffText", bold = true },
    dipherWordAdd = { link = "DiffText", bold = true },
    dipherThreadRange = { link = "Visual" },
    -- staged-hunk overlay (§8.1): a muted full-line bg replacing the vivid
    -- add/delete so a staged hunk reads as set-aside rather than a live change
    dipherStagedLine = { link = "CursorLine" },
    -- file panel chrome (§8.6)
    dipherPanelHeader = { link = "Title" },
    dipherPanelRoot = { link = "Directory" },
    dipherPanelHelp = { link = "Comment" },
    dipherPanelDir = { link = "Directory" },
    -- dimmed "·parent/" trailer after a basename in the name listing (§8.6)
    dipherPanelContext = { link = "Comment" },
    -- history panel commit rows (§8.4): the author column (sha reuses dipherPanelDir,
    -- the date reuses dipherPanelHelp, the counts reuse the panel count groups) and
    -- the ref-decoration tag in branch-range mode
    dipherHistoryAuthor = { link = "Identifier" },
    dipherHistoryRef = { link = "Special" },
}

-- the first defined fg among `groups`, else `fallback` (a 0xRRGGBB int). lets the
-- palette ride the theme (e.g. green from `Added`/`GitSignsAdd`) yet still render
-- on bare themes that define none of them
---@param groups string[]
---@param fallback integer
---@return integer
local function fg_of(groups, fallback)
    for _, name in ipairs(groups) do
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        if ok and hl and hl.fg then
            return hl.fg
        end
    end
    return fallback
end

-- semantic status palette, resolved against the current theme. GitSigns groups
-- come first because that's where themes (and the user's diffview config) keep the
-- vivid git colours; `Added`/`Changed`/`Removed` are often duller or unset. order
-- and fallbacks mirror the user's diff-highlights.lua so the panel matches diffview
---@return table<string, integer>
local function palette()
    return {
        green = fg_of({ "GitSignsAdd", "Added", "diffAdded", "String" }, 0xa6e3a1),
        yellow = fg_of({ "GitSignsChange", "Changed", "diffChanged", "WarningMsg" }, 0xf9e2af),
        red = fg_of({ "GitSignsDelete", "Removed", "diffRemoved", "ErrorMsg" }, 0xf38ba8),
        blue = fg_of({ "Function", "Directory" }, 0x89b4fa),
        orange = fg_of({ "Number", "Constant" }, 0xfab387),
        grey = fg_of({ "Comment", "NonText" }, 0x6c7086),
    }
end

-- map the panel's status/count groups onto the palette (status letters, §8.6
-- "Status presentation", and the right-aligned +N -M counts)
---@param p table<string, integer>
---@return table<string, vim.api.keyset.highlight>
local function status_groups(p)
    return {
        dipherPanelAdd = { fg = p.green },
        dipherPanelModify = { fg = p.yellow },
        dipherPanelDelete = { fg = p.red },
        dipherPanelRename = { fg = p.blue },
        dipherPanelUnmerged = { fg = p.orange },
        dipherPanelUntracked = { fg = p.green },
        dipherPanelCountAdd = { fg = p.green },
        dipherPanelCountDelete = { fg = p.red },
        -- the staged-hunk gutter glyph (§8.1): green for "in the index"
        dipherStagedSign = { fg = p.green },
    }
end

-- (re)define all default highlight groups. `default = true` keeps user overrides
-- authoritative; the ColorScheme autocmd (registered once by setup) re-resolves the
-- palette so it tracks theme changes
local function apply()
    local groups = vim.tbl_extend("error", {}, LINKS, status_groups(palette()))
    for name, val in pairs(groups) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, val))
    end
end

local registered = false

function M.setup()
    apply()
    if not registered then
        registered = true
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = vim.api.nvim_create_augroup("dipher.highlights", { clear = true }),
            callback = apply,
        })
    end
end

return M
