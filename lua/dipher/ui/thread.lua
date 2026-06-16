-- pure builder for the inline thread overlay (§6.4): a thread -> the virt_lines chunk
-- rows for the header-rule + left-spine style. each row is a list of { text, hl }
-- chunks ready for an extmark's virt_lines; every chunk carries a real highlight group
-- so apply + golden tests need no nil handling. no vim state, so it's unit-tested like
-- the foldtext / word-diff builders. relative time is injected (opts.reltime) to keep
-- the builder pure and its output deterministic

local M = {}

local SPINE = "│  "
local SPINE_BLANK = "│"
local TOP = "┌─ "
local BOT = "└─ "
local SNIPPET_MAX = 50

---@param thread table
---@return string  -- the state chrome highlight group
local function state_hl(thread)
    if thread.is_pending then
        return "dipherThreadPending"
    elseif thread.resolved then
        return "dipherThreadResolved"
    end
    return "dipherThread"
end

-- split on newlines, dropping a single trailing newline so a github-style "body\n"
-- doesn't add a blank row. vim-free (the builder runs under busted, no nvim runtime)
---@param s string
---@return string[]
local function split_lines(s)
    local out = {}
    for line in ((s or ""):gsub("\n$", "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

-- the first non-empty line of `body`, truncated for the collapsed summary
---@param body string
---@return string
local function snippet(body)
    local first = (body or ""):match("[^\n]*") or ""
    if #first > SNIPPET_MAX then
        return first:sub(1, SNIPPET_MAX - 1) .. "…"
    end
    return first
end

-- a comment's header row: `<lead>@author · <time>`, lead being the top rule (first
-- comment) or the spine (replies)
---@param comment table
---@param lead string
---@param hl string
---@param reltime fun(ts: string): string
---@return table[]
local function comment_header(comment, lead, hl, reltime)
    return {
        { lead, hl },
        { "@" .. (comment.author or "?"), hl },
        { " · " .. reltime(comment.created_at or ""), "dipherThreadMeta" },
    }
end

-- a comment's body, one spine row per source line (an empty body still yields one row
-- so the box never collapses to a bare header)
---@param comment table
---@param hl string
---@param rows table[]  -- accumulator
local function append_body(comment, hl, rows)
    for _, line in ipairs(split_lines(comment.body or "")) do
        rows[#rows + 1] = { { SPINE, hl }, { line, "dipherThreadBody" } }
    end
end

-- the collapsed one-liner: `└─ N comments · @author: "first body line…"`
---@param thread table
---@param hl string
---@return table[]
local function build_collapsed(thread, hl)
    local comments = thread.comments or {}
    local first = comments[1] or {}
    local n = #comments
    return {
        {
            { BOT, hl },
            { (n == 1 and "1 comment" or n .. " comments") .. " · ", "dipherThreadMeta" },
            { "@" .. (first.author or "?") .. ": ", hl },
            { '"' .. snippet(first.body) .. '"', "dipherThreadMeta" },
        },
    }
end

-- build the virt_lines chunk rows for `thread`. opts.collapsed renders the summary
-- line; opts.reltime formats `created_at` (inject for purity/determinism)
---@param thread table
---@param opts { collapsed?: boolean, reltime?: fun(ts: string): string }|nil
---@return table[]  -- list of rows; each row is a list of { text, hl } chunks
function M.build(thread, opts)
    opts = opts or {}
    local reltime = opts.reltime or function(ts)
        return ts
    end
    local hl = state_hl(thread)
    if opts.collapsed then
        return build_collapsed(thread, hl)
    end

    local comments = thread.comments or {}
    local rows = {}

    -- header: first comment on the top rule, with the resolved / draft state tags
    local header = comment_header(comments[1] or {}, TOP, hl, reltime)
    if thread.resolved then
        header[#header + 1] = { " · ✓ resolved", "dipherThreadMeta" }
    end
    if thread.is_pending then
        header[#header + 1] = { " (draft)", hl }
    end
    rows[#rows + 1] = header
    append_body(comments[1] or {}, hl, rows)

    -- replies: a blank spine row, then sub-header + body, in input order (the caller
    -- has already ordered the thread's comments)
    for i = 2, #comments do
        rows[#rows + 1] = { { SPINE_BLANK, hl } }
        rows[#rows + 1] = comment_header(comments[i], SPINE, hl, reltime)
        append_body(comments[i], hl, rows)
    end

    -- footer rule: reply count and the open/resolved state, joined by " · "
    local replies = math.max(0, #comments - 1)
    local parts = {}
    if replies > 0 then
        parts[#parts + 1] = "↳ " .. (replies == 1 and "1 reply" or replies .. " replies")
    end
    if not thread.resolved then
        parts[#parts + 1] = "open"
    end
    if #parts > 0 then
        rows[#rows + 1] = { { BOT, hl }, { table.concat(parts, " · "), "dipherThreadMeta" } }
    else
        rows[#rows + 1] = { { "└─", hl } }
    end
    return rows
end

return M
