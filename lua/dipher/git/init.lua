-- local git source: the runtime half of the diff source layer (§8.1). resolves a
-- repo, turns a rev spec (rev.lua) into concrete old/new content, and opens a
-- view. local diffs are fast and offline, so reads run synchronously here: the
-- latency discipline (§7.5) is about the PR sidecar hot path, not local git.
-- pure parsing/grammar lives in git/rev.lua; this module only does I/O + wiring

local rev = require("dipher.git.rev")

local M = {}

-- the three working-tree side refs (§8.6 slice B). staged diffs read HEAD↔index,
-- unstaged diffs read index↔worktree; an untracked file is absent from the index
-- so its index read returns nil and the diff renders as a pure add
local HEAD = { kind = "rev", rev = "HEAD", label = "HEAD" }
local INDEX = { kind = "index", label = "INDEX" }
local WORKTREE = { kind = "worktree", label = "WORKTREE" }

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- run git in `cwd`. returns stdout on success, or nil + stderr on failure
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

-- repo root containing `path` (a file or directory), or nil if not in a repo
---@param path string
---@return string|nil
function M.root(path)
    local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    local out = git({ "rev-parse", "--show-toplevel" }, dir)
    return out and chomp(out) or nil
end

-- resolve an unresolved merge_base ref to a concrete rev; other refs pass through.
-- returns nil on failure (e.g. unrelated histories), with a notification
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

-- read a side's content for `relpath` (repo-root-relative). returns the content
-- (possibly ""), or nil when the file is absent on that side (added/deleted);
-- callers treat nil as an empty file so the diff renders an add/delete
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

-- list changed files for a resolved source (used by the picker/panel, §8.6)
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

-- resolve a source's refs to concrete revs (merge_base -> rev). returns nil if a
-- merge-base can't be found. do this once per source, then open each file against
-- the result; the picker and panel both share it
---@param source dipher.git.Source
---@param root string
---@return dipher.git.Source|nil
function M.resolve(source, root)
    local old = resolve_ref(source.old, root)
    local new = resolve_ref(source.new, root)
    if not (old and new) then
        return nil
    end
    return { old = old, new = new }
end

-- build a DiffModel for one changed file under an already-resolved source.
-- renames read the old side from `previous_path`; an absent side reads as empty.
-- `head` (the current branch) rides along for the synthetic buffer's statusline
---@param source dipher.git.Source -- resolved (no merge_base refs)
---@param root string
---@param file dipher.git.ChangedFile|dipher.FileEntry
---@param head string|nil
---@return dipher.DiffModel
function M.model(source, root, file, head)
    local old_path = file.previous_path or file.path
    return require("dipher.model.diff").build({
        path = file.path,
        old_rev = source.old.label,
        new_rev = source.new.label,
        old_text = M.read(source.old, root, old_path) or "",
        new_text = M.read(source.new, root, file.path) or "",
        head = head,
        root = root,
    })
end

-- the current branch name (for the buffer statusline), or nil on a detached HEAD
---@param root string
---@return string|nil
local function head_branch(root)
    local out = git({ "rev-parse", "--abbrev-ref", "HEAD" }, root)
    local name = out and chomp(out) or nil
    return (name and name ~= "HEAD") and name or nil
end

-- the "Showing changes for:" footer label (§8.6): the user's rev spec, or the
-- resolved HEAD commit for the default uncommitted view (mirrors diffview)
---@param args string[]
---@param root string
---@return string|nil
local function footer_label(args, root)
    if #args == 0 then
        local out = git({ "rev-parse", "HEAD" }, root)
        return out and chomp(out) or nil
    elseif #args == 2 then
        return args[1] .. ".." .. args[2]
    end
    return table.concat(args, " ")
end

-- open the diff for one changed file under an already-resolved source
---@param source dipher.git.Source
---@param root string
---@param file dipher.git.ChangedFile
---@return dipher.View
function M.open_file(source, root, file)
    return require("dipher").diff_model(M.model(source, root, file))
end

-- parse a `git diff --numstat -z [...]` run into a path -> counts map. returns an
-- empty map on git failure so callers degrade to zeroed counts
---@param args string[] -- extra args after `diff --numstat -z`
---@param root string
---@return table<string, { additions: integer, deletions: integer }>
local function numstat(args, root)
    local full = { "diff", "--numstat", "-z" }
    vim.list_extend(full, args)
    return rev.parse_numstat(git(full, root) or "")
end

-- the change set as panel FileEntry records: one flat list with `+N -M` counts,
-- used for rev-pair sources. working-tree sources use status_sections instead
---@param source dipher.git.Source -- resolved
---@param root string
---@return dipher.FileEntry[]
function M.file_entries(source, root)
    local counts = numstat(rev.diff_args(source), root)
    local out = {}
    for _, f in ipairs(M.changed_files(source, root)) do
        local c = counts[f.path] or {}
        out[#out + 1] = {
            path = f.path,
            status = f.status,
            additions = c.additions or 0,
            deletions = c.deletions or 0,
            previous_path = f.previous_path,
        }
    end
    return out
end

-- working-tree status as panel sections: Staged / Unstaged / Untracked (§8.6
-- slice B). git status compares HEAD/index/worktree, so it only models the
-- default HEAD-vs-worktree source; rev-pair sources use file_entries instead.
-- a file edited in both index and worktree (e.g. "MM") appears in both Staged
-- (X status, HEAD↔index counts) and Unstaged (Y status, index↔worktree counts).
-- empty sections are dropped by the caller
---@param root string
---@return dipher.panel.Section[]
function M.status_sections(root)
    local entries = rev.parse_status(git({ "status", "--porcelain=v1", "-z", "-uall" }, root) or "")
    local staged_counts = numstat({ "--cached" }, root)
    local unstaged_counts = numstat({}, root)
    local staged, unstaged, untracked = {}, {}, {}
    for _, s in ipairs(entries) do
        if s.x == "?" then
            untracked[#untracked + 1] =
                { path = s.path, status = "?", additions = 0, deletions = 0, staged = false }
        else
            -- previous_path only belongs to whichever side carries the rename:
            -- an "RM" file is renamed HEAD↔index but plain-modified index↔worktree
            if s.x ~= " " then
                local c = staged_counts[s.path] or {}
                staged[#staged + 1] = {
                    path = s.path,
                    status = s.x,
                    additions = c.additions or 0,
                    deletions = c.deletions or 0,
                    staged = true,
                    previous_path = (s.x == "R" or s.x == "C") and s.previous_path or nil,
                }
            end
            if s.y ~= " " then
                local c = unstaged_counts[s.path] or {}
                unstaged[#unstaged + 1] = {
                    path = s.path,
                    status = s.y,
                    additions = c.additions or 0,
                    deletions = c.deletions or 0,
                    staged = false,
                    previous_path = (s.y == "R" or s.y == "C") and s.previous_path or nil,
                }
            end
        end
    end
    return {
        { title = "Staged", entries = staged },
        { title = "Unstaged", entries = unstaged },
        { title = "Untracked", entries = untracked },
    }
end

-- file-level staging ops driven from the panel (§8.6 slice C); each is whole-file
-- and operates on the repo root. hunk-level staging stays in the diff view (§8.1)

---@param root string
---@param path string
function M.stage(root, path)
    git({ "add", "--", path }, root)
end

---@param root string
---@param path string
function M.unstage(root, path)
    git({ "reset", "-q", "HEAD", "--", path }, root)
end

---@param root string
function M.stage_all(root)
    git({ "add", "-A" }, root)
end

---@param root string
function M.unstage_all(root)
    git({ "reset", "-q", "HEAD" }, root)
end

-- discard a file's changes: untracked or a staged-add drops the file (unstaging
-- first if needed); anything tracked in HEAD reverts index + worktree to HEAD.
-- destructive, so the panel confirms before calling this
---@param root string
---@param entry dipher.FileEntry
function M.discard(root, entry)
    local abs = root .. "/" .. entry.path
    if entry.status == "?" then
        os.remove(abs)
    elseif entry.status == "A" then
        git({ "reset", "-q", "HEAD", "--", entry.path }, root) -- unstage the add
        os.remove(abs)
    else
        git({ "checkout", "HEAD", "--", entry.path }, root) -- revert index + worktree
    end
end

-- drop empty sections so the panel never shows a bare "Staged (0)" header; returns
-- the kept sections and their total entry count
---@param sections dipher.panel.Section[]
---@return dipher.panel.Section[] nonempty, integer total
local function nonempty_sections(sections)
    local out, total = {}, 0
    for _, sec in ipairs(sections) do
        if #sec.entries > 0 then
            out[#out + 1] = sec
            total = total + #sec.entries
        end
    end
    return out, total
end

-- the repo to operate on: the current file's repo if it's a real file, else cwd
---@return string|nil
local function repo_root()
    local file = vim.api.nvim_buf_get_name(0)
    local anchor = (file ~= "" and vim.fn.filereadable(file) == 1) and file or vim.fn.getcwd()
    return M.root(anchor)
end

-- true when `source` is the default HEAD-vs-worktree view: the only source git
-- status can model as Staged/Unstaged/Untracked sections (§8.6 slice B). rev-pair
-- and merge-base sources (old is a sha, not HEAD) stay a single counted list
---@param source dipher.git.Source -- resolved
---@return boolean
local function is_worktree_status(source)
    return source.old.kind == "rev" and source.old.rev == "HEAD" and source.new.kind == "worktree"
end

-- :Dipher panel: open (or toggle) the file panel (§8.6) over a git change set.
-- selecting a file re-sources the one View in place rather than spawning a new
-- one. `opts.rev` is the rev spec; position/listing/height/width pass through to
-- the panel and are runtime-adjustable via Panel.current(). `opts.open_first`
-- selects the first file straight away (DiffviewOpen-style: bare `:Dipher`)
---@class dipher.git.PanelOpts
---@field rev? string|string[]
---@field position? string
---@field listing? string
---@field height? integer
---@field width? integer
---@field open_first? boolean
---@param opts dipher.git.PanelOpts
---@return dipher.Panel|nil
function M.panel(opts)
    local Panel = require("dipher.panel")
    local open = Panel.current()
    if open and open:is_open() then
        open:close()
        return nil
    end

    local root = repo_root()
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    local args = type(opts.rev) == "table" and opts.rev or (opts.rev and { opts.rev }) or {}
    local source = M.resolve(rev.source(args), root)
    if not source then
        return
    end
    local branch = head_branch(root) -- once per source, for the buffer statuslines

    -- model_for picks the (old, new) pair per entry: working-tree sections diff by
    -- the entry's staged flag (staged = HEAD↔index, else index↔worktree), while a
    -- rev-pair list diffs every entry against the one resolved source. `actions`
    -- (file-level staging) is only meaningful for the worktree-status source
    local sections, model_for, actions
    if is_worktree_status(source) then
        sections = M.status_sections(root)
        model_for = function(entry)
            local s = entry.staged and { old = HEAD, new = INDEX }
                or { old = INDEX, new = WORKTREE }
            return M.model(s, root, entry, branch)
        end
        actions = {
            stage = function(entry)
                M.stage(root, entry.path)
            end,
            unstage = function(entry)
                M.unstage(root, entry.path)
            end,
            stage_all = function()
                M.stage_all(root)
            end,
            unstage_all = function()
                M.unstage_all(root)
            end,
            discard = function(entry)
                M.discard(root, entry)
            end,
            reload = function()
                return (nonempty_sections(M.status_sections(root)))
            end,
        }
    else
        sections = { { title = "Changes", entries = M.file_entries(source, root) } }
        model_for = function(entry)
            return M.model(source, root, entry, branch)
        end
    end

    local nonempty, total = nonempty_sections(sections)
    if total == 0 then
        return notify("no changes for this source")
    end

    local view ---@type dipher.View|nil -- the single diff view the panel drives
    local panel = Panel.new({
        sections = nonempty,
        root = vim.fn.fnamemodify(root, ":~"), -- ~-relative repo path for the header
        footer = footer_label(args, root),
        actions = actions,
        quarter_scroll = require("dipher").get_config().keymaps.quarter_scroll,
        listing = opts.listing,
        position = opts.position,
        height = opts.height,
        width = opts.width,
        on_select = function(entry)
            local model = model_for(entry)
            if view and view:is_open() then
                view:set_source(model)
            else
                view = require("dipher").diff_model(model)
            end
        end,
        on_close = function()
            if view and view:is_open() then
                view:close()
            end
        end,
    }):open()
    if opts.open_first then
        panel:select() -- cursor sits on the first file row after :open
    end
    return panel
end

-- :Dipher close: tear down the whole local session: the panel (which closes the
-- diff view it drives via on_close) or, failing that, a bare diff view
function M.close()
    local panel = require("dipher.panel").current()
    if panel then
        return panel:close()
    end
    local view = require("dipher.view").current()
    if view then
        return view:close()
    end
    notify("no dipher view open")
end

return M
