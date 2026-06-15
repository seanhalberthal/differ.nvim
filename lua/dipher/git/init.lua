-- local git source: the runtime half of the diff source layer (§8.1). resolves a
-- repo, turns a rev spec (rev.lua) into concrete old/new content, and opens a
-- view. local diffs are fast and offline, so reads run synchronously here: the
-- latency discipline (§7.5) is about the PR sidecar hot path, not local git.
-- pure parsing/grammar lives in git/rev.lua; this module only does I/O + wiring

local rev = require("dipher.git.rev")
local patch = require("dipher.git.patch")
local log = require("dipher.git.log")
local watch = require("dipher.git.watch")

local M = {}

-- the three working-tree side refs (§8.6 slice B). staged diffs read HEAD↔index,
-- unstaged diffs read index↔worktree; an untracked file is absent from the index
-- so its index read returns nil and the diff renders as a pure add
local HEAD = { kind = "rev", rev = "HEAD", label = "HEAD" }
local INDEX = { kind = "index", label = "INDEX" }
local WORKTREE = { kind = "worktree", label = "WORKTREE" }

-- git's canonical empty-tree object: the "old" side for a root commit (no parent),
-- so its files list and read as pure adds (§8.4 history)
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

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

-- run a session in its own tabpage (like diffview, §8.6): the tab :Dipher was invoked
-- from is never touched, so ending the session drops the tab and returns there with
-- the dashboard / file / window layout intact. `tab split` carries the current buffer
-- in, so it stays displayed in the invoking tab and isn't wiped when the diff takes
-- the session window. returns the tab to return to and the new session tab
---@return integer return_tab, integer session_tab
local function open_session_tab()
    local return_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tab split")
    return return_tab, vim.api.nvim_get_current_tabpage()
end

-- close a session's tabpage, never leaving zero tabs (mirrors diffview). a no-op when
-- it's already gone: closing the last session window can collapse the tab first
---@param tab integer|nil
local function close_session_tab(tab)
    if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then
        return
    end
    if #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd("tabnew")
    end
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
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

-- the commits behind a history request (§8.4), newest first. an empty list on git
-- failure (e.g. the path has no history). pure arg-building/parsing live in git/log.lua
---@param root string
---@param opts dipher.git.LogOpts
---@return dipher.git.Commit[]
function M.log_commits(root, opts)
    return log.parse_log(git(log.log_args(opts), root) or "")
end

-- the "old" side for a commit's own diff: its first parent, or the empty tree when
-- it's a root commit (so the commit lists/reads as pure adds). §8.4 history
---@param root string
---@param sha string
---@return dipher.git.Ref
local function parent_or_empty(root, sha)
    local has_parent = git({ "rev-parse", "--verify", "--quiet", sha .. "^" }, root)
    if has_parent then
        return { kind = "rev", rev = sha .. "^", label = sha:sub(1, 7) .. "^" }
    end
    return { kind = "rev", rev = EMPTY_TREE, label = "(root)" }
end

-- the commits in a rev-range, newest first, for branch-range history (§8.4, dp).
-- `--no-merges` drops merge commits; a symmetric `a...b` range adds `--right-only`
-- to keep only the right side (the branch's own commits), mirroring the dp flow
---@param root string
---@param range string
---@return dipher.git.Commit[]
function M.range_commits(root, range)
    local extra = vim.split(range, "%s+", { trimempty = true })
    extra[#extra + 1] = "--no-merges"
    if range:find("...", 1, true) then
        extra[#extra + 1] = "--right-only"
    end
    return M.log_commits(root, { extra = extra })
end

-- the files one commit changed, as panel FileEntry[] with +N -M counts (§8.4 range
-- history): the commit diffed against its parent (or the empty tree for a root commit)
---@param root string
---@param sha string
---@return dipher.FileEntry[]
function M.commit_files(root, sha)
    local source = {
        old = parent_or_empty(root, sha),
        new = { kind = "rev", rev = sha, label = sha:sub(1, 7) },
    }
    return M.file_entries(source, root)
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
---@param file { path: string, previous_path?: string } -- only the path(s) are read
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

-- apply a single-hunk patch to the index (§8.1 hunk staging). `--unidiff-zero`
-- because the patch carries no context (built straight from the hunk model);
-- `--reverse` unstages. git apply is atomic, so a non-applying patch fails cleanly
-- with stderr rather than half-writing. returns ok + git's stderr on failure
---@param root string
---@param text string  -- the unified diff to apply
---@param reverse boolean
---@return boolean ok, string|nil err
function M.apply_patch(root, text, reverse)
    local cmd = { "git", "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn" }
    if reverse then
        cmd[#cmd + 1] = "--reverse"
    end
    cmd[#cmd + 1] = "-"
    local res = vim.system(cmd, { cwd = root, stdin = text, text = true }):wait()
    if res.code ~= 0 then
        return false, res.stderr
    end
    return true
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
    -- a live session (sidebar shown or hidden) toggles the sidebar's visibility in
    -- place; the diff view + session tab survive. :Dipher close ends the session
    local existing = Panel.current()
    if existing then
        existing:toggle()
        return existing
    end

    -- the file + line :Dipher was invoked from, so open_first can open that file at
    -- that line (mapped into the diff) instead of the first listed file
    local origin_file = vim.api.nvim_buf_get_name(0)
    local origin_line = vim.api.nvim_win_get_cursor(0)[1]

    local root = repo_root()
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    -- repo-relative origin path; resolve symlinks so the prefix strip lines up with
    -- git's realpath toplevel (as M.history does), and only when the file is under it
    local origin_rel ---@type string|nil
    if origin_file ~= "" and vim.fn.filereadable(origin_file) == 1 then
        local resolved = vim.fn.resolve(origin_file)
        if resolved:sub(1, #root + 1) == root .. "/" then
            origin_rel = resolved:sub(#root + 2)
        end
    end
    -- normalise the rev spec to an arg list (explicit branches so the type narrows)
    local args ---@type string[]
    if type(opts.rev) == "table" then
        args = opts.rev
    elseif opts.rev then
        args = { opts.rev }
    else
        args = {}
    end
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
    local panel ---@type dipher.Panel|nil -- forward ref so staging can refresh it
    local watcher ---@type dipher.git.Watcher|nil -- fs watcher, set for worktree panels
    local on_edit_unstage ---@type fun(path: string)|nil -- assigned below; passed to the view

    -- hunk-level staging (§8.1): plain modifications (status "M", same path both
    -- sides) stage by hunk; a new file (untracked "?" or staged add "A") diffs
    -- empty<->content as one whole-file hunk, so it stages as a unit; renames/
    -- copies/deletes stay file-level in the panel. the view keeps its diff frozen
    -- and marks staged hunks in place, so it tracks per-hunk state and asks `apply`
    -- to patch one hunk: forward stages, `reverse` unstages, and `offset` shifts the
    -- patch past already-staged hunks before it. `initial` is every hunk's starting
    -- state (an unstaged diff opens unstaged, a staged one opens staged). the panel
    -- refreshes its counts after each op
    local stageable = is_worktree_status(source)
    local active_entry ---@type dipher.FileEntry|nil -- the file the view currently shows

    -- a cheap fingerprint of the diff's inputs: HEAD + porcelain status (the index
    -- side) + the shown file's mtime/size (the worktree side). external refreshes act
    -- only when it moved, so a stray event doesn't re-source over an in-progress
    -- in-dipher staging session, and a dipher stage records it so the index write it
    -- caused doesn't read as outside. content-aware so a worktree edit counts too
    local function git_signature()
        if not stageable then
            return ""
        end
        local sig = (git({ "rev-parse", "HEAD" }, root) or "")
            .. "\0"
            .. (git({ "status", "--porcelain=v1", "-z", "-uall" }, root) or "")
        if active_entry then
            local st = (vim.uv or vim.loop).fs_stat(root .. "/" .. active_entry.path)
            if st and st.mtime then
                sig = sig .. "\0" .. st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size
            end
        end
        return sig
    end
    local last_sig = git_signature()

    local function refresh_panel()
        if panel then
            panel:refresh()
        end
        -- record state so the next external event doesn't read this in-dipher op as an
        -- outside change and re-source over the in-place staged marks
        last_sig = git_signature()
    end
    ---@param entry dipher.FileEntry
    ---@return dipher.view.Staging|nil
    local function stage_for(entry)
        if not stageable then
            return nil
        end
        if entry.status == "M" then
            return {
                initial = entry.staged and "staged" or "unstaged",
                apply = function(model, hunk, offset, reverse)
                    local p = patch.hunk(model.path, hunk, model.old_text, model.new_text, offset)
                    local ok, err = M.apply_patch(root, p, reverse)
                    if not ok then
                        local op = reverse and "unstage" or "stage"
                        notify(("hunk %s failed: %s"):format(op, err or ""), vim.log.levels.ERROR)
                    end
                    return ok
                end,
                refresh = refresh_panel,
            }
        end
        -- a new file is a single whole-file hunk against an empty side, so there's
        -- nothing to patch partially: staging that hunk is a whole-file `git add`,
        -- unstaging a `git reset` back to untracked
        if entry.status == "?" or entry.status == "A" then
            return {
                initial = entry.staged and "staged" or "unstaged",
                apply = function(_, _, _, reverse)
                    if reverse then
                        M.unstage(root, entry.path)
                    else
                        M.stage(root, entry.path)
                    end
                    return true
                end,
                refresh = refresh_panel,
            }
        end
        return nil
    end

    -- (re)source the diff view from an entry's current git state. false when the
    -- entry has no diff anymore (committed / fully staged / reverted outside dipher).
    -- `focus_line` (a new-side file line) holds the cursor across an in-place refresh
    -- of the same file; without it the view lands on the first unstaged hunk
    ---@param entry dipher.FileEntry
    ---@param focus_line integer|nil
    ---@return boolean shown
    local function show_entry(entry, focus_line)
        local model = model_for(entry)
        if #model.hunks == 0 then
            return false
        end
        local staging = stage_for(entry)
        if view and view:is_open() then
            view:set_source(model, staging, focus_line and { focus_line = focus_line } or nil)
        else
            view = require("dipher").diff_model(model, {
                staging = staging,
                can_stage = stageable,
                on_edit_unstage = on_edit_unstage,
            })
        end
        active_entry = entry
        if watcher then
            watcher:watch_file(root .. "/" .. entry.path)
        end
        last_sig = git_signature() -- record the state we're now showing
        return true
    end

    -- the current changed-file entries for a path: a file can have a staged side and
    -- an unstaged side, and an external op (lazygit) can empty the side you were on
    ---@param path string
    ---@return dipher.FileEntry[]
    local function entries_for_path(path)
        local out = {}
        for _, sec in ipairs(M.status_sections(root)) do
            for _, e in ipairs(sec.entries) do
                if e.path == path then
                    out[#out + 1] = e
                end
            end
        end
        return out
    end

    -- edit-in-review on a staged diff (§8.1, flow C): unstage the whole file so the
    -- staged change returns to the worktree, then re-source the diff to the file's now-
    -- unstaged view so the edit lands somewhere the diff reflects. driven explicitly by
    -- the view (not the watcher, whose re-source is suppressed by the staging signature)
    ---@param path string
    on_edit_unstage = function(path)
        M.unstage(root, path)
        refresh_panel() -- the file moves to the Unstaged section; records last_sig
        for _, e in ipairs(entries_for_path(path)) do
            if not e.staged then
                show_entry(e) -- switch the diff to index↔worktree, updating active_entry
                return
            end
        end
    end

    -- after an external git change (lazygit, a tmux-pane commit, `:!git`): refresh the
    -- list, then re-source the open diff so it reflects the new state too rather than
    -- staying frozen. gated on the signature so unrelated terminal events are no-ops
    local function refresh_external()
        -- a debounced watcher fire (or a queued schedule) can land after the panel is
        -- gone; bail before touching its deleted buffer
        if not (panel and panel:is_open()) then
            return
        end
        if git_signature() == last_sig then
            return
        end
        if panel then
            panel:refresh()
        end
        if view and view:is_open() and active_entry then
            -- the content shifted underneath the user; hold the cursor near where it was
            -- (the nearest hunk to its new-side line) rather than snapping to the top
            local focus_line = view:cursor_new_line()
            -- re-target the view to the file's current changes, preferring the side it
            -- was on; staging the whole file empties that side, so fall back to the
            -- other. show_entry records the signature when it sources
            local candidates = entries_for_path(active_entry.path)
            local pick = candidates[1]
            for _, e in ipairs(candidates) do
                if e.staged == active_entry.staged then
                    pick = e
                    break
                end
            end
            if pick and show_entry(pick, focus_line) then
                return
            end
        end
        -- no view, or the file went fully clean: leave the diff and just record state
        last_sig = git_signature()
    end

    -- watch the git dir and the shown file's dir so an external change (lazygit, an
    -- editor, a commit) re-sources instantly, not just on focus. worktree panels only:
    -- rev-pair diffs are against immutable SHAs and never go stale
    if stageable then
        local git_dir = git({ "rev-parse", "--absolute-git-dir" }, root)
        git_dir = git_dir and chomp(git_dir) or nil
        if git_dir then
            watcher = watch.new({ git_dir = git_dir, on_change = refresh_external })
        end
    end

    -- per-call opts (e.g. `:Dipher panel`) win, else the resolved config's panel
    -- defaults, else Panel.new's own hardcoded fallbacks
    local cfg = require("dipher").get_config()
    local panel_cfg = cfg.panel or {}
    local return_tab, session_tab = open_session_tab()
    panel = Panel.new({
        sections = nonempty,
        root = vim.fn.fnamemodify(root, ":~"), -- ~-relative repo path for the header
        footer = footer_label(args, root),
        actions = actions,
        on_external_change = refresh_external,
        keymaps = cfg.keymaps.panel,
        listing = opts.listing or panel_cfg.listing,
        position = opts.position or panel_cfg.position,
        height = opts.height or panel_cfg.height,
        width = opts.width or panel_cfg.width,
        progress = panel_cfg.progress,
        on_select = function(entry)
            if show_entry(entry) then
                return
            end
            -- a stale entry (committed or changed outside dipher) has an empty diff;
            -- refresh the list rather than opening a blank view
            refresh_panel()
            notify(("no changes for %s"):format(entry.path))
        end,
        on_close = function()
            if watcher then
                watcher:stop()
            end
            if view and view:is_open() then
                view:close()
            end
            close_session_tab(session_tab)
        end,
    }):open()
    panel.return_tab = return_tab
    if opts.open_first then
        -- land on the file (and line) :Dipher was run from when it's in the change
        -- set, else the first file; leave the cursor in the diff, not the panel
        local on_origin = origin_rel and panel:focus_file(origin_rel)
        panel:select(true)
        if on_origin and view then
            view:focus_new_line(origin_line)
        end
    end
    return panel
end

-- :Dipher log [path] / the `dh` verb: single-file history (§8.4). lists the file's
-- commits in a dedicated history panel; selecting/stepping a commit re-sources the
-- one driven View to that commit vs its parent. read-only (no staging). `opts.path`
-- defaults to the current buffer's file; position passes through to the panel
---@class dipher.git.HistoryOpts
---@field path? string
---@field position? string
---@return dipher.History|nil
function M.history(opts)
    local History = require("dipher.history")
    local open = History.current()
    if open and open:is_open() then
        open:close()
        return nil
    end

    local file = opts.path and vim.fn.fnamemodify(opts.path, ":p") or vim.api.nvim_buf_get_name(0)
    if file == "" or vim.fn.filereadable(file) == 0 then
        return notify("no file to show history for", vim.log.levels.WARN)
    end
    -- resolve symlinks so the prefix strip below lines up with git's toplevel, which
    -- is itself realpath-resolved (e.g. macOS /var -> /private/var)
    file = vim.fn.resolve(file)
    local root = M.root(file)
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    local relpath = file:sub(#root + 2) -- strip "<root>/"; file is under root

    local commits = M.log_commits(root, { path = relpath })
    if #commits == 0 then
        return notify("no history for " .. relpath)
    end
    local branch = head_branch(root)

    -- a commit's diff is the patch it introduced: the file at <commit> vs its
    -- parent. the root commit's parent (<sha>^) doesn't resolve, so M.read returns
    -- nil -> empty old side -> a pure add, which is correct for the introducing commit
    ---@param commit dipher.git.Commit
    ---@return dipher.DiffModel
    local function model_for(commit)
        local source = {
            old = { kind = "rev", rev = commit.short .. "^", label = commit.short .. "^" },
            new = { kind = "rev", rev = commit.sha, label = commit.short },
        }
        return M.model(source, root, { path = relpath }, branch)
    end

    local view ---@type dipher.View|nil -- the single diff view the panel drives
    local cfg = require("dipher").get_config()
    local return_tab, session_tab = open_session_tab()
    local history = History.new({
        commits = commits,
        path = vim.fn.fnamemodify(file, ":~"),
        keymaps = cfg.keymaps.history,
        relative_dates = cfg.relative_dates,
        position = opts.position,
        on_select = function(commit)
            local model = model_for(commit)
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
            close_session_tab(session_tab)
        end,
    }):open()
    history.return_tab = return_tab
    return history
end

-- :Dipher log <range> / the `dp` verb: branch-range history (§8.4). lists the
-- range's commits in the history panel; a commit expands to its files (lazy), and
-- selecting/stepping a file re-sources the one driven View to that file at the
-- commit vs its parent. one expandable panel, read-only (no staging)
---@class dipher.git.RangeHistoryOpts
---@field range? string
---@field position? string
---@return dipher.History|nil
function M.range_history(opts)
    local History = require("dipher.history")
    local open = History.current()
    if open and open:is_open() then
        open:close()
        return nil
    end

    local range = opts.range
    if not range or range == "" then
        return notify("range history needs a rev-range (e.g. main...HEAD)", vim.log.levels.WARN)
    end
    local root = repo_root()
    if not root then
        return notify("not inside a git repository", vim.log.levels.WARN)
    end
    local commits = M.range_commits(root, range)
    if #commits == 0 then
        return notify("no commits in " .. range)
    end
    local branch = head_branch(root)

    local view ---@type dipher.View|nil -- the single diff view the panel drives
    local cfg = require("dipher").get_config()
    local return_tab, session_tab = open_session_tab()
    local history = History.new({
        commits = commits,
        mode = "range",
        path = range, -- the header shows the range in place of a file path
        keymaps = cfg.keymaps.history,
        relative_dates = cfg.relative_dates,
        position = opts.position,
        expand = function(commit)
            return M.commit_files(root, commit.sha)
        end,
        on_file = function(commit, entry)
            local source = {
                old = parent_or_empty(root, commit.sha),
                new = { kind = "rev", rev = commit.sha, label = commit.short },
            }
            local model = M.model(source, root, entry, branch)
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
            close_session_tab(session_tab)
        end,
    }):open()
    history.return_tab = return_tab
    return history
end

-- :Dipher close: tear down the whole local session: the panel (which closes the
-- diff view it drives via on_close) or, failing that, a bare diff view
function M.close()
    local panel = require("dipher.panel").current()
    if panel then
        return panel:close()
    end
    local history = require("dipher.history").current()
    if history then
        return history:close()
    end
    local view = require("dipher.view").current()
    if view then
        return view:close()
    end
    notify("no dipher view open")
end

return M
