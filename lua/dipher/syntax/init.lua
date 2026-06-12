-- Syntax highlight pass (§6.5): treesitter highlights for the diffed code,
-- GitHub/JetBrains-style — but never by parsing the derived buffer (that jumble of
-- interleaved old/new, meta separators and filler would mis-parse). Instead parse
-- the *real* old_text/new_text, collect captures in source coords, and project
-- them onto the buffer through the line map's from_old/from_new (§6.2 derived
-- behavior). Extmark-only, in its own namespace, so it refreshes independently of
-- the diff layer and never touches buffer text or the map (invariant 2).

local project = require("dipher.syntax.project")

local M = {}

local ns = vim.api.nvim_create_namespace("dipher.syntax")

-- §6.5 layering: syntax foreground sits *under* the diff line background (paint
-- uses 100) and word-level spans (200), so the diff state always reads on top.
local PRIORITY = 90

-- Resolve a treesitter language for `path`, or nil when there's no filetype, no
-- mapped language, or the parser isn't installed — in which case the pass is
-- skipped and the view stays plain (diff highlights still apply).
---@param path string
---@return string|nil
local function resolve_lang(path)
    if not path or path == "" then
        return nil
    end
    local ft = vim.filetype.match({ filename = path })
    if not ft then
        return nil
    end
    local lang = vim.treesitter.language.get_lang(ft)
    if not lang then
        return nil
    end
    if not pcall(vim.treesitter.language.add, lang) then
        return nil
    end
    return lang
end

-- Parse `text` and collect highlight captures in source coordinates. Mirrors the
-- core highlighter: hl group is `@<capture>.<lang>`, captures named `_…` are
-- internal and skipped. Multi-line captures are clipped to one entry per line;
-- injections (embedded languages) are deferred for v1 — only the primary tree.
---@param text string
---@param lang string
---@return dipher.SyntaxCapture[]
local function captures_for(text, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then
        return {}
    end
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return {}
    end
    local tree = parser:parse()[1]
    if not tree then
        return {}
    end

    local lines = vim.split(text, "\n", { plain = true })
    local out = {}
    for id, node in query:iter_captures(tree:root(), text, 0, -1) do
        local name = query.captures[id]
        if not vim.startswith(name, "_") then
            local hl = "@" .. name .. "." .. lang
            local srow, scol, erow, ecol = node:range()
            if srow == erow then
                out[#out + 1] = { row = srow, col_start = scol, col_end = ecol, hl = hl }
            else
                -- head to EOL, full middle lines, tail to ecol (skip an empty tail)
                out[#out + 1] =
                    { row = srow, col_start = scol, col_end = #(lines[srow + 1] or ""), hl = hl }
                for r = srow + 1, erow - 1 do
                    out[#out + 1] =
                        { row = r, col_start = 0, col_end = #(lines[r + 1] or ""), hl = hl }
                end
                if ecol > 0 then
                    out[#out + 1] = { row = erow, col_start = 0, col_end = ecol, hl = hl }
                end
            end
        end
    end
    return out
end

-- Apply the syntax pass to one column's buffer: parse the real source(s) the
-- column draws from (old, new, or both for a unified/stacked column), project the
-- captures through the map, and paint them as extmarks. No-op when the language
-- has no parser. Idempotent — clears its namespace first, so it doubles as a
-- refresh after a re-render.
---@param bufnr integer
---@param column dipher.Column
---@param model dipher.DiffModel
function M.apply(bufnr, column, model)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local lang = resolve_lang(model.path)
    if not lang then
        return
    end

    local marks = {}
    if column.side == "old" or column.side == "unified" then
        vim.list_extend(
            marks,
            project.project(captures_for(model.old_text, lang), column.map.from_old)
        )
    end
    if column.side == "new" or column.side == "unified" then
        vim.list_extend(
            marks,
            project.project(captures_for(model.new_text, lang), column.map.from_new)
        )
    end

    for _, m in ipairs(marks) do
        -- end_col is byte-identical to the source line (same content), but guard
        -- against any treesitter range quirk rather than abort the whole pass.
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, m.row, m.col_start, {
            end_col = m.col_end,
            hl_group = m.hl,
            priority = PRIORITY,
        })
    end
end

return M
