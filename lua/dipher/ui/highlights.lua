-- highlight group definitions for diff lines, word-level spans, threads, and the
-- file panel. structural groups are plain links; the diff line + word backgrounds
-- and the panel's status + count groups carry a semantic palette (green add / yellow
-- modify / blue rename / orange conflict / red delete) derived from the active theme
-- with hex fallbacks, mirroring the user's diffview/octo colours. the line + word
-- backgrounds are a coherent two-tone pair from one colour per side (see
-- diff_bg_groups). all are set with `default = true` so explicit user overrides win,
-- and re-applied on `ColorScheme` so theme switches propagate

local M = {}

-- static links: body diff layers and structural panel chrome
---@type table<string, vim.api.keyset.highlight>
local LINKS = {
    -- thread overlay (§6.4): all thread groups (range background, panel-tinted chrome,
    -- meta, body) ride the palette + theme bg in thread_groups
    -- our own cursor-line overlay: CursorLine is low-priority when it has no
    -- foreground (`:h hl-CursorLine`), so it loses to the diff line backgrounds; we
    -- repaint it as a line_hl_group above them. links to CursorLine to track the theme
    dipherCursorLine = { link = "CursorLine" },
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

-- the first defined bg among `groups`, else `fallback` (a 0xRRGGBB int)
---@param groups string[]
---@param fallback integer
---@return integer
local function bg_of(groups, fallback)
    for _, name in ipairs(groups) do
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        if ok and hl and hl.bg then
            return hl.bg
        end
    end
    return fallback
end

-- mix `top` over `base` by `alpha` (0..1); both 0xRRGGBB ints, arithmetic only so
-- there's no bit-op dependency
---@param top integer
---@param base integer
---@param alpha number
---@return integer
local function blend(top, base, alpha)
    local function chan(shift)
        local t = math.floor(top / shift) % 256
        local b = math.floor(base / shift) % 256
        return math.floor(b + (t - b) * alpha + 0.5) % 256
    end
    return chan(65536) * 65536 + chan(256) * 256 + chan(1)
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

-- thread overlay groups (§6.4): every chunk sits on a faint panel tint so the comment
-- block reads as a non-code overlay (the jetbrains look), not more code. the chrome
-- (spine + header/footer rules + author) is state-coloured: open active (blue),
-- resolved receded (grey), pending draft (orange); meta is dim; body keeps the normal
-- fg. all share the one panel bg blended off Normal
---@param p table<string, integer>
---@return table<string, vim.api.keyset.highlight>
local function thread_groups(p)
    local base = bg_of({ "Normal" }, 0x14161b)
    local panel = blend(p.blue, base, 0.12) -- subtle blue-tinted panel
    return {
        dipherThread = { fg = p.blue, bg = panel },
        dipherThreadResolved = { fg = p.grey, bg = panel },
        dipherThreadPending = { fg = p.orange, bg = panel },
        dipherThreadMeta = { fg = p.grey, bg = panel },
        dipherThreadBody = { bg = panel }, -- fg unset -> Normal, readable on the tint
        -- the lines a range comment covers: the same blue family as the panel, a touch
        -- stronger so it reads over the diff bg, but far gentler than the old Visual link
        dipherThreadRange = { bg = blend(p.blue, base, 0.2) },
    }
end

-- coherent two-tone diff backgrounds: a quiet line tint and a richer same-hue word
-- patch, both blended from one vivid colour per side (the add/delete fg) over the
-- editor bg. deriving line and patch from the same source keeps the hue identical
-- and steps only saturation/lightness, so the changed words read as a deeper block
-- of the line they sit on (the claude-style look) instead of a clashing overlay.
-- the vivid fg is a mid-tone, so the same alpha lightens on dark themes and darkens
-- on light ones, no per-theme branching. word spans are bg-only (no fg/bold) so the
-- syntax foreground shows through. these replace the old DiffAdd/DiffDelete links
---@param p table<string, integer>
---@return table<string, vim.api.keyset.highlight>
local function diff_bg_groups(p)
    local base = bg_of({ "Normal" }, 0x14161b)
    local line, word = 0.16, 0.42 -- blend weights toward the vivid colour; tune to taste
    return {
        dipherLineAdd = { bg = blend(p.green, base, line) },
        dipherLineDelete = { bg = blend(p.red, base, line) },
        dipherWordAdd = { bg = blend(p.green, base, word) },
        dipherWordDelete = { bg = blend(p.red, base, word) },
    }
end

-- (re)define all default highlight groups. `default = true` keeps user overrides
-- authoritative; the ColorScheme autocmd (registered once by setup) re-resolves the
-- palette so it tracks theme changes
local function apply()
    local p = palette()
    local groups =
        vim.tbl_extend("error", {}, LINKS, status_groups(p), diff_bg_groups(p), thread_groups(p))
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
