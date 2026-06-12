-- Git source resolution: pure mapping from :Dipher args to a (old, new) pair of
-- side refs, the `git diff` args that list that pairing's changed files, and a
-- parser for `--name-status -z` output. No Neovim or subprocess here — exec lives
-- in git/init.lua — so this stays unit-testable under plain busted.

local M = {}

---@class dipher.git.Ref
---@field kind "worktree"|"index"|"rev"|"merge_base"
---@field rev string|nil    -- kind == "rev"
---@field base string|nil   -- kind == "merge_base": one side of the merge-base
---@field head string|nil   -- kind == "merge_base": the other side
---@field label string      -- display name (becomes old_rev/new_rev on the model)

---@class dipher.git.Source
---@field old dipher.git.Ref
---@field new dipher.git.Ref

local WORKTREE = { kind = "worktree", label = "WORKTREE" }

---@param rev string
---@return dipher.git.Ref
local function rev_ref(rev)
    return { kind = "rev", rev = rev, label = rev }
end

-- An unresolved merge-base ref; git/init.lua resolves it to a concrete rev.
---@param base string
---@param head string
---@param label string
---@return dipher.git.Ref
local function merge_base_ref(base, head, label)
    return { kind = "merge_base", base = base, head = head, label = label }
end

-- Resolve :Dipher args into a source pairing (§8.1). Mirrors git/diffview rev
-- syntax so existing muscle memory carries over. These forms cover the whole
-- daily loop (uncommitted / branch-total / range / since-rev); staged-only has no
-- entry — staged/unstaged is a file-panel concern (§8.6), not a diff-open flag:
--   (none)              -> HEAD vs worktree              (all uncommitted changes)
--   <a>..<b>            -> <a> vs <b>                     (plain two-dot range)
--   <a>...<b>           -> merge-base(a,b) vs <b>         (three-dot; since they diverged)
--   <a>...              -> merge-base(a,HEAD) vs worktree (branch total, incl. uncommitted)
--   <a> <b>             -> <a> vs <b>
--   <rev>               -> <rev> vs worktree             (changes since <rev>, incl. uncommitted)
---@param args string[]|nil
---@return dipher.git.Source
function M.source(args)
    args = args or {}
    local first = args[1]
    if first == nil or first == "" then
        return { old = rev_ref("HEAD"), new = WORKTREE }
    end
    -- Three-dot before two-dot (it's a superset). Empty RHS is the branch-total
    -- convenience: merge-base vs the working tree, so uncommitted work is included.
    local ta, tb = first:match("^(.-)%.%.%.(.*)$")
    if ta and ta ~= "" then
        if tb == "" then
            return { old = merge_base_ref(ta, "HEAD", ta .. "..."), new = WORKTREE }
        end
        return { old = merge_base_ref(ta, tb, ta .. "..." .. tb), new = rev_ref(tb) }
    end
    local a, b = first:match("^(.-)%.%.(.+)$")
    if a and a ~= "" and b then
        return { old = rev_ref(a), new = rev_ref(b) }
    end
    if args[2] and args[2] ~= "" then
        return { old = rev_ref(first), new = rev_ref(args[2]) }
    end
    return { old = rev_ref(first), new = WORKTREE }
end

-- The arguments to append after `git diff --name-status -z` to list this source's
-- changed files. Expects a *resolved* source (merge_base already turned into a
-- rev by git/init.lua), so old is always a rev:
--   rev vs worktree -> `git diff <rev>`   (uncommitted diff against rev)
--   rev vs rev      -> `git diff <a> <b>`
---@param source dipher.git.Source
---@return string[]
function M.diff_args(source)
    local o, n = source.old, source.new
    if n.kind == "worktree" then
        return { o.rev }
    end
    return { o.rev, n.rev }
end

-- Split a NUL-delimited byte string into fields. Pure (avoids vim.split's vim dep)
-- and trailing-NUL tolerant, matching git's `-z` framing.
---@param s string
---@return string[]
local function nul_split(s)
    local out, start = {}, 1
    while start <= #s do
        local z = s:find("\0", start, true)
        if not z then
            out[#out + 1] = s:sub(start)
            break
        end
        out[#out + 1] = s:sub(start, z - 1)
        start = z + 1
    end
    return out
end

---@class dipher.git.ChangedFile
---@field status string                -- single-letter: A/M/D/R/C/T...
---@field path string
---@field previous_path string|nil     -- source path on rename/copy

-- Parse `git diff --name-status -z [...]` output. Rename/copy records carry the
-- similarity-suffixed status (e.g. "R100") followed by old then new path.
---@param out string
---@return dipher.git.ChangedFile[]
function M.parse_name_status(out)
    local toks = nul_split(out)
    local files, i = {}, 1
    while i <= #toks do
        local status = toks[i]
        i = i + 1
        if status == "" then
            break -- trailing empty field from the final NUL
        end
        local code = status:sub(1, 1)
        if code == "R" or code == "C" then
            local prev, path = toks[i], toks[i + 1]
            i = i + 2
            files[#files + 1] = { status = code, path = path, previous_path = prev }
        else
            files[#files + 1] = { status = code, path = toks[i] }
            i = i + 1
        end
    end
    return files
end

return M
