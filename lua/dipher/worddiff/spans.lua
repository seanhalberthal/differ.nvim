-- fragment diff: paired lines -> changed byte-col spans, pure lua, no nvim API.
-- a pure LCS over token streams (not vim.diff) so spans stay testable
-- under plain busted. lines are short, so O(n*m) is fine

local tokenize = require("dipher.worddiff.tokenize")
local pair = require("dipher.worddiff.pair")

local M = {}

---@class dipher.PairSpans
---@field old dipher.SubSpan[]
---@field new dipher.SubSpan[]

-- mark which tokens are common to both streams via LCS backtrack
---@param a dipher.Token[]
---@param b dipher.Token[]
---@return boolean[] keep_a, boolean[] keep_b
local function common_tokens(a, b)
    local n, m = #a, #b
    -- dp[i][j] = LCS length of a[i..n], b[j..m]
    local dp = {}
    for i = 0, n do
        dp[i] = {}
        dp[i][m] = 0
    end
    for j = 0, m do
        dp[n][j] = 0
    end
    for i = n - 1, 0, -1 do
        for j = m - 1, 0, -1 do
            if a[i + 1].text == b[j + 1].text then
                dp[i][j] = dp[i + 1][j + 1] + 1
            else
                dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
            end
        end
    end

    local keep_a, keep_b = {}, {}
    local i, j = 0, 0
    while i < n and j < m do
        if a[i + 1].text == b[j + 1].text then
            keep_a[i + 1] = true
            keep_b[j + 1] = true
            i, j = i + 1, j + 1
        elseif dp[i + 1][j] >= dp[i][j + 1] then
            i = i + 1
        else
            j = j + 1
        end
    end
    return keep_a, keep_b
end

-- merge runs of non-common tokens into byte-col spans
---@param tokens dipher.Token[]
---@param keep boolean[]
---@return dipher.SubSpan[]
local function spans_from(tokens, keep)
    local out = {}
    local i = 1
    local n = #tokens
    while i <= n do
        if not keep[i] then
            local col_start = tokens[i].col_start
            local col_end = tokens[i].col_end
            local has_content = tokens[i].text:match("%S") ~= nil
            local j = i + 1
            while j <= n and not keep[j] do
                col_end = tokens[j].col_end
                has_content = has_content or tokens[j].text:match("%S") ~= nil
                j = j + 1
            end
            -- a purely-whitespace run is alignment churn (e.g. gofmt re-padding a
            -- struct), not a real edit; pairing already ignores whitespace, so drop
            -- it here too rather than lighting up the gap on unchanged lines
            if has_content then
                out[#out + 1] = { col_start = col_start, col_end = col_end }
            end
            i = j
        else
            i = i + 1
        end
    end
    return out
end

-- emit word-level spans for a single old/new line pair
---@param old_line string
---@param new_line string
---@param mode "word"|"char"
---@return dipher.PairSpans
function M.emit(old_line, new_line, mode)
    if old_line == new_line then
        return { old = {}, new = {} }
    end
    local old_toks = tokenize.tokenize(old_line, mode)
    local new_toks = tokenize.tokenize(new_line, mode)
    local keep_old, keep_new = common_tokens(old_toks, new_toks)
    return {
        old = spans_from(old_toks, keep_old),
        new = spans_from(new_toks, keep_new),
    }
end

-- pair a hunk's lines and emit per-line spans for the matched pairs.
-- returns sparse arrays keyed by intra-hunk line index (1-based); unpaired
-- lines have no entry and degrade to whole-line highlighting
---@param hunk dipher.Hunk
---@param threshold number
---@param mode "word"|"char"
---@return table<integer, dipher.SubSpan[]> old_spans, table<integer, dipher.SubSpan[]> new_spans
function M.for_hunk(hunk, threshold, mode)
    local pairs_ = pair.pair(hunk.old_lines, hunk.new_lines, threshold)
    local old_spans, new_spans = {}, {}
    for _, p in ipairs(pairs_) do
        if p.old and p.new then
            local s = M.emit(hunk.old_lines[p.old], hunk.new_lines[p.new], mode)
            old_spans[p.old] = s.old
            new_spans[p.new] = s.new
        end
    end
    return old_spans, new_spans
end

return M
