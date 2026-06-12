-- Local git source: the runtime half of the diff source layer (§8.1). Resolves a
-- repo, turns a rev spec (rev.lua) into concrete old/new content, and opens a
-- View. Local diffs are fast and offline, so reads run synchronously here — the
-- latency discipline (§7.5) is about the PR sidecar hot path, not local git.
-- Pure parsing/grammar lives in git/rev.lua; this module only does I/O + wiring.

local rev = require("dipher.git.rev")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- Run git in `cwd`. Returns stdout on success, or nil + stderr on failure.
---@param args string[]
---@param cwd string
---@return string|nil stdout, string|nil stderr
local function git(args, cwd)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
    if res.code ~= 0 then
        return nil, res.stderr
    end
    return res.stdout
end

local function chomp(s)
    return (s:gsub("%s+$", ""))
end

-- Repo root containing `path` (a file or directory), or nil if not in a repo.
---@param path string
---@return string|nil
function M.root(path)
    local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    local out = git({ "rev-parse", "--show-toplevel" }, dir)
    return out and chomp(out) or nil
end

-- Resolve an unresolved merge_base ref to a concrete rev; other refs pass through.
-- Returns nil on failure (e.g. unrelated histories), with a notification.
---@param ref dipher.git.Ref
---@param root string
---@return dipher.git.Ref|nil
local function resolve_ref(ref, root)
    if ref.kind ~= "merge_base" then
        return ref
    end
    local out = git({ "merge-base", ref.base, ref.head }, root)
    if not out then
        notify(("no merge-base between %s and %s"):format(ref.base, ref.head), vim.log.levels.ERROR)
        return nil
    end
    return { kind = "rev", rev = chomp(out), label = ref.label }
end

-- Read a side's content for `relpath` (repo-root-relative). Returns the content
-- (possibly ""), or nil when the file is absent on that side (added/deleted) —
-- callers treat nil as an empty file so the diff renders an add/delete.
---@param ref dipher.git.Ref
---@param root string
---@param relpath string
---@return string|nil
function M.read(ref, root, relpath)
    if ref.kind == "worktree" then
        local abs = root .. "/" .. relpath
        if vim.fn.filereadable(abs) == 0 then
            return nil
        end
        local fd = io.open(abs, "rb")
        if not fd then
            return nil
        end
        local data = fd:read("*a")
        fd:close()
        return data
    end
    -- index (stage 0) is `:path`; a rev is `<rev>:path`
    local spec = (ref.kind == "index" and ":" or (ref.rev .. ":")) .. relpath
    return git({ "show", spec }, root) -- nil if the path is absent in that tree
end

-- List changed files for a resolved source (used by the picker/panel, §8.6).
---@param source dipher.git.Source
---@param root string
---@return dipher.git.ChangedFile[]
function M.changed_files(source, root)
    local args = { "diff", "--name-status", "-z" }
    vim.list_extend(args, rev.diff_args(source))
    local out = git(args, root)
    if not out then
        return {}
    end
    return rev.parse_name_status(out)
end

-- :Dipher [revspec] — open a diff of the current file against the resolved source.
-- The changed-file picker and panel arrive in the next slices (§8.1/§8.6); this
-- MVP diffs the current buffer's file.
---@param fargs string[]
---@return dipher.View|nil
function M.open(fargs)
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then
        return notify("no file in the current buffer", vim.log.levels.WARN)
    end
    local root = M.root(file)
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    local relpath = vim.fs.relpath(root, file)
    if not relpath then
        return notify("current file is outside the repo root", vim.log.levels.WARN)
    end

    local source = rev.source(fargs)
    local old = resolve_ref(source.old, root)
    local new = resolve_ref(source.new, root)
    if not (old and new) then
        return nil
    end

    return require("dipher").diff({
        path = relpath,
        old_rev = old.label,
        new_rev = new.label,
        old_text = M.read(old, root, relpath) or "",
        new_text = M.read(new, root, relpath) or "",
    })
end

return M
