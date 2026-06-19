-- git log parsing for file history: pure mapping from a history request to
-- `git log` args, and a parser for its output. no nvim or subprocess here (exec
-- lives in git/init.lua) so this stays unit-testable under plain busted

local M = {}

---@class differ.git.Commit
---@field sha string       -- full commit hash
---@field short string     -- abbreviated hash
---@field author string    -- author name (%an)
---@field epoch integer    -- author date as a unix timestamp (%at), formatted by util/date
---@field refs string      -- ref decorations (%D), e.g. "HEAD -> main, tag: v1"; "" when none
---@field subject string
---@field additions integer -- lines added by this commit, for the listed path(s)
---@field deletions integer -- lines removed by this commit, for the listed path(s)

-- fields are joined by US (\31). US can't appear in any field (sha/short/author/
-- epoch/refs are constrained, the subject is a single line), so a line carrying US
-- is a commit header; the `--numstat` rows that follow it never do, keeping the two
-- unambiguous in one pass
local FMT = "%H%x1f%h%x1f%an%x1f%at%x1f%D%x1f%s"

---@class differ.git.LogOpts
---@field path? string      -- single-file history: only commits touching this path
---@field extra? string[]   -- extra args before the `--` (the dp range slice uses this)

-- the `git log` invocation for a history request. `--numstat` rides along so each
-- commit's per-file +N/-M is parsed from the same call. `extra` is the seam the
-- branch-range walk will fill with `--right-only --no-merges <range>`
---@param opts differ.git.LogOpts|nil
---@return string[]
function M.log_args(opts)
    opts = opts or {}
    local args = { "log", "--numstat", "--pretty=format:" .. FMT }
    for _, a in ipairs(opts.extra or {}) do
        args[#args + 1] = a
    end
    if opts.path then
        args[#args + 1] = "--"
        args[#args + 1] = opts.path
    end
    return args
end

-- split `s` on the single-char separator `sep`. pure (avoids vim.split), matching
-- rev.lua's nul_split. an empty input yields no fields
---@param s string
---@param sep string
---@return string[]
local function split_on(s, sep)
    local out, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            break
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + 1
    end
    return out
end

-- parse combined `git log --numstat --pretty=format:<FMT>` output into commits,
-- newest first (git's order). a line carrying US is a commit header; a `+\t-\t path`
-- row adds to the current commit's counts (binary `-` counts read as 0); blanks are
-- skipped. a header short of its six fields is dropped
---@param out string
---@return differ.git.Commit[]
function M.parse_log(out)
    local commits = {}
    local cur ---@type differ.git.Commit|nil
    for _, line in ipairs(split_on(out, "\n")) do
        if line:find("\31", 1, true) then
            local f = split_on(line, "\31")
            if #f >= 6 then
                -- a subject could in theory carry a US; re-join the tail to be safe
                local subject = f[6]
                for j = 7, #f do
                    subject = subject .. "\31" .. f[j]
                end
                cur = {
                    sha = f[1],
                    short = f[2],
                    author = f[3],
                    epoch = tonumber(f[4]) or 0,
                    refs = f[5],
                    subject = subject,
                    additions = 0,
                    deletions = 0,
                }
                commits[#commits + 1] = cur
            end
        elseif cur then
            local add, del = line:match("^([%d%-]+)\t([%d%-]+)\t")
            if add then
                cur.additions = cur.additions + (tonumber(add) or 0)
                cur.deletions = cur.deletions + (tonumber(del) or 0)
            end
        end
    end
    return commits
end

return M
