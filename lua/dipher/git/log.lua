-- git log parsing for file history (§8.4): pure mapping from a history request to
-- `git log` args, and a parser for its output. no nvim or subprocess here (exec
-- lives in git/init.lua) so this stays unit-testable under plain busted

local M = {}

---@class dipher.git.Commit
---@field sha string       -- full commit hash
---@field short string     -- abbreviated hash
---@field author string
---@field date string      -- author date (--date=short, YYYY-MM-DD)
---@field subject string

-- fields are joined by US (\31), records by git's inter-record newline. US can't
-- appear in any field (sha/short/author/date are constrained, the subject is a
-- single line), so the framing is unambiguous
local FMT = "%H%x1f%h%x1f%an%x1f%ad%x1f%s"

---@class dipher.git.LogOpts
---@field path? string      -- single-file history: only commits touching this path
---@field extra? string[]   -- extra args before the `--` (the dp range slice uses this)

-- the `git log` invocation for a history request. `extra` is the seam the
-- branch-range walk will fill with `--right-only --no-merges <range>`
---@param opts dipher.git.LogOpts|nil
---@return string[]
function M.log_args(opts)
    opts = opts or {}
    local args = { "log", "--pretty=format:" .. FMT, "--date=short" }
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

-- parse `git log --pretty=format:<FMT>` output into commits, newest first (git's
-- order). blank lines are skipped; a record short of its five fields is dropped
---@param out string
---@return dipher.git.Commit[]
function M.parse_log(out)
    local commits = {}
    for _, line in ipairs(split_on(out, "\n")) do
        if line ~= "" then
            local f = split_on(line, "\31")
            if #f >= 5 then
                -- a subject could in theory carry a US; re-join the tail to be safe
                local subject = f[5]
                for j = 6, #f do
                    subject = subject .. "\31" .. f[j]
                end
                commits[#commits + 1] = {
                    sha = f[1],
                    short = f[2],
                    author = f[3],
                    date = f[4],
                    subject = subject,
                }
            end
        end
    end
    return commits
end

return M
