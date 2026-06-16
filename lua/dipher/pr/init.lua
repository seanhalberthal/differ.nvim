-- the PR frontend session (§8.2, §8.6): pick a PR, list its files in the reused file
-- panel (with a viewed column), and diff each file from the sidecar's base/head
-- blobs. it mirrors git/init.lua's module-local session shape, owning the session
-- tab + panel + the one driven View; the panel and View are source-agnostic, so this
-- only swaps the model source (blobs over IPC) for git's local reads. every sidecar
-- call is async (cb(err, result)); the client already schedules its dispatch

local repo = require("dipher.pr.repo")
local client = require("dipher.pr.client")
local viewed = require("dipher.pr.viewed")

local M = {}

-- the live session: coords, pr coords + meta (incl. pinned base/head shas), the panel
-- and driven View, and a per-path blob memo. base/head are pinned for the session, so
-- a path's versions can't go stale; the memo is the seam phase-6 prefetch writes into
---@type table|nil
local session = nil

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- a typed sidecar error -> a single notification, with an actionable hint for the
-- codes the user can fix (§7.6)
---@type table<string, string>
local CODE_HINT = {
    auth = "run gh auth login",
    gh_missing = "install gh or set GH_TOKEN",
    rate_limited = "github rate limit hit, retry shortly",
}
---@param err table|nil
local function notify_err(err)
    local code = (err and err.code) or "internal"
    local msg = (err and err.message) or code
    local hint = CODE_HINT[code]
    notify(hint and (msg .. " (" .. hint .. ")") or msg, vim.log.levels.ERROR)
end

---@param sha string|nil
---@return string
local function short(sha)
    return sha and sha:sub(1, 7) or "?"
end

-- run a session in its own tabpage (like git/init.lua): the invoking tab is never
-- touched, so ending the session drops the tab and returns there
---@return integer return_tab, integer session_tab
local function open_session_tab()
    local return_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tab split")
    return return_tab, vim.api.nvim_get_current_tabpage()
end

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

-- github's file-status words -> the single-letter codes the panel keys highlights on
-- (panel/init.lua STATUS_HL). the sidecar forwards the REST status verbatim, so the
-- translation lives here
---@type table<string, string>
local STATUS = {
    added = "A",
    removed = "D",
    modified = "M",
    renamed = "R",
    copied = "C",
    changed = "M",
    unchanged = "M",
}

-- map get_pr `files` to panel FileEntry[] (§8.6). pure, so the mapping is unit-tested:
-- counts/previous_path pass through, status collapses to its letter code, and
-- viewed_state collapses to the boolean the panel renders as a checkbox (VIEWED and
-- DISMISSED both count as viewed, §8.2)
---@param files table[]
---@return dipher.FileEntry[]
function M.map_files(files)
    local out = {}
    for _, f in ipairs(files or {}) do
        out[#out + 1] = {
            path = f.path,
            status = STATUS[f.status] or f.status,
            additions = f.additions or 0,
            deletions = f.deletions or 0,
            previous_path = f.previous_path,
            viewed = f.viewed_state == "VIEWED" or f.viewed_state == "DISMISSED",
        }
    end
    return out
end

---@param ts string|nil
---@return string
local function reltime(ts)
    if type(ts) ~= "string" or ts == "" then
        return ""
    end
    local date = require("dipher.util.date")
    local epoch = date.parse_iso(ts)
    if not epoch then
        return ts
    end
    return date.relative(epoch)
end

-- predictive prefetch (§9.1 phase 6, minimal slice): warm the immediate neighbours of
-- the shown file into the per-path memo so sequential ]f/[f / ]u/[u don't wait on a
-- round-trip. best-effort and silent: a speculative read, not a user-initiated one, so
-- a failure just leaves the memo cold (the on-demand path fetches it later) and never
-- notifies. window of 1 each side; shas are pinned, so warmed blobs can't go stale
local LOOKAHEAD = 1
---@param entry dipher.FileEntry
local function prefetch_around(entry)
    if not session then
        return
    end
    local idx = viewed.index_of(session.entries, entry)
    if not idx then
        return
    end
    session.prefetching = session.prefetching or {}
    for _, dir in ipairs({ -1, 1 }) do
        for step = 1, LOOKAHEAD do
            local nb = session.entries[idx + dir * step]
            if nb and not session.versions[nb.path] and not session.prefetching[nb.path] then
                local path = nb.path
                session.prefetching[path] = true
                local refs = { base = session.pr_meta.base_sha, head = session.pr_meta.head_sha }
                client.get_file_versions(session.pr, path, refs, function(err, vers)
                    if not session then
                        return -- session torn down while the prefetch was in flight
                    end
                    session.prefetching[path] = nil
                    if not err and vers then
                        session.versions[path] = vers
                    end
                end)
            end
        end
    end
end

-- (re)source the one driven View for a file. base/head shas are pinned for the
-- session, so the per-path memo makes re-visits instant (no IPC hop); `focus_line`
-- holds the cursor across an in-place refresh of the same file
---@param entry dipher.FileEntry
---@param focus_line integer|nil
local function show_file(entry, focus_line)
    local function render(vers)
        local base, head = vers.base or {}, vers.head or {}
        local model = require("dipher.model.diff").build({
            path = entry.path,
            old_rev = short(session.pr_meta.base_sha),
            new_rev = short(session.pr_meta.head_sha),
            old_text = (base.missing and "") or base.content or "",
            new_text = (head.missing and "") or head.content or "",
            root = session.root,
        })
        if session.view and session.view:is_open() then
            session.view:set_source(model, nil, focus_line and { focus_line = focus_line } or nil)
        else
            session.view = require("dipher").diff_model(model, {
                staging = false,
                can_stage = false,
                extra_keymaps = session.diff_extra_keymaps, -- ]u/[u on the diff surface (§8.2)
                -- re-apply the thread overlay after a layout/context re-render, and
                -- expand the thread under the cursor as it moves (§6.4)
                on_rerender = function()
                    require("dipher.pr.threads").apply(session)
                end,
                on_cursor = function()
                    require("dipher.pr.threads").on_cursor(session)
                end,
            })
        end
        prefetch_around(entry) -- warm the neighbours so the next step is instant
        require("dipher.pr.threads").refresh(session) -- (re)paint inline comment threads (§6.4)
    end

    local cached = session.versions[entry.path]
    if cached then
        return render(cached)
    end
    -- pass entry.path, not previous_path: the sidecar fetches one path at both refs,
    -- so a rename shows its head content as an add (true rename diffing is a later
    -- sidecar concern; this keeps open-and-navigate correct for the common cases).
    -- the pinned shas skip the sidecar's prRefs round-trip (§7.5 latency discipline)
    local refs = { base = session.pr_meta.base_sha, head = session.pr_meta.head_sha }
    client.get_file_versions(session.pr, entry.path, refs, function(err, vers)
        if err then
            return notify_err(err)
        end
        if not (session and session.panel and session.panel:is_open()) then
            return -- session torn down while the blob was in flight
        end
        session.versions[entry.path] = vers
        render(vers)
    end)
end

-- flip a file's viewed flag optimistically, repaint, then reconcile to the server's
-- returned viewed_state (roll back + flag on error, §11). cheap and idempotent, so
-- the one optimistic update phase 4 allows (§8.2). a no-op if already at `target`
---@param entry dipher.FileEntry
---@param target boolean
local function mark_viewed(entry, target)
    if not (session and session.panel) or entry.viewed == target then
        return
    end
    local prev = entry.viewed
    entry.viewed = target
    session.panel:repaint()
    client.set_file_viewed(session.pr, entry.path, target, function(err, res)
        if not (session and session.panel and session.panel:is_open()) then
            return -- session torn down while the mutation was in flight
        end
        if err then
            entry.viewed = prev
            session.panel:repaint()
            return notify_err(err)
        end
        -- reconcile: DISMISSED counts as viewed, like map_files (§8.2)
        local server = res and (res.viewed_state == "VIEWED" or res.viewed_state == "DISMISSED")
        if server ~= nil and server ~= entry.viewed then
            entry.viewed = server
            session.panel:repaint()
        end
    end)
end

-- <Tab>: flip the viewed checkbox of the file under the panel cursor
local function toggle_viewed()
    local entry = session and session.panel and session.panel:current_entry()
    if entry then
        mark_viewed(entry, not entry.viewed)
    end
end

-- ]u/[u: jump to the nearest unviewed file (no wrap; notify when none remain).
-- forward nav marks the file being left as viewed, like ]f; backward never does
---@param direction "next"|"prev"
---@param keep_focus boolean  -- true when invoked from the diff (stay in the diff window)
local function nav_unviewed(direction, keep_focus)
    if not (session and session.panel) then
        return
    end
    local cur = session.panel:current_entry()
    local from = viewed.index_of(session.entries, cur) or 0
    local target = viewed.next_unviewed(session.entries, from, direction)
    if not target then
        return notify(
            direction == "next" and "no more unviewed files" or "no previous unviewed files"
        )
    end
    if direction == "next" and cur then
        mark_viewed(cur, true)
    end
    session.panel:goto_path(session.entries[target].path, keep_focus)
end

-- panel on_step: a forward ]f/[f step marks the file just left as viewed (§8.2).
-- backward never marks, and a plain select (which never steps) marks nothing
---@param direction "next"|"prev"
---@param left dipher.FileEntry|nil
local function on_step(direction, left)
    if direction == "next" and left then
        mark_viewed(left, true)
    end
end

-- the thread anchor group under the cursor in the diff, or nil. all four thread
-- actions key off the cursor row, so they read the same way from a keymap or a script
---@return table|nil  -- { key, bufnr, row, threads }
local function cursor_anchor()
    if not (session and session.view and session.view:is_open()) then
        return
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return require("dipher.pr.threads").anchor_at(session, buf, row)
end

-- gc: collapse/expand the thread group under the cursor (§6.4). an explicit toggle
-- overrides the cursor-peek default until toggled back; re-apply swaps the boxes in
-- place (stacked) or shows/hides the float (split), and a no-op off a thread row
function M.toggle_thread()
    local anchor = cursor_anchor()
    if not anchor then
        return notify("no review thread on this line")
    end
    local threads = require("dipher.pr.threads")
    threads.toggle_group(session, anchor)
    threads.apply(session)
    threads.on_cursor(session) -- reopen/close the split float to match the new state
end

-- ]t/[t: move the cursor to the next/prev thread anchor in the current diff column,
-- scanning the overlay index rather than the map so thread blocks (virt_lines, not
-- real rows) never enter ]c hunk motion. no wrap; notify when none remain
---@param direction "next"|"prev"
local function nav_thread(direction)
    if not (session and session.view and session.view:is_open()) then
        return
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local target =
        require("dipher.pr.threads").next_anchor(session.thread_anchors, buf, row, direction)
    if not target then
        return notify(direction == "next" and "no more threads" or "no previous threads")
    end
    vim.api.nvim_win_set_cursor(win, { target, 0 })
end

function M.next_thread()
    nav_thread("next")
end

function M.prev_thread()
    nav_thread("prev")
end

-- gr / :Dipher pr resolve: toggle the resolved state of the thread under the cursor.
-- optimistic — flip + re-apply (highlight swap) immediately, then reconcile to the
-- server's returned state, rolling back + flagging on error (§11). one line can stack
-- several threads, so it acts on the first open one (else the first, to unresolve);
-- the sidecar flushes its thread cache after the mutation (§7.5)
function M.resolve()
    local anchor = cursor_anchor()
    if not anchor then
        return notify("no review thread on this line")
    end
    local target
    for _, t in ipairs(anchor.threads) do
        if not t.resolved then
            target = t
            break
        end
    end
    target = target or anchor.threads[1]
    if target.is_pending or not target.thread_id then
        return notify("this thread can't be resolved yet")
    end
    local threads = require("dipher.pr.threads")
    local new_state = not target.resolved
    target.resolved = new_state
    threads.apply(session)
    client.resolve_thread(session.pr, target.thread_id, new_state, function(err, res)
        if not (session and session.view and session.view:is_open()) then
            return -- session torn down while the mutation was in flight
        end
        if err then
            target.resolved = not new_state
            threads.apply(session)
            return notify_err(err)
        end
        if res and res.resolved ~= nil and res.resolved ~= target.resolved then
            target.resolved = res.resolved
            threads.apply(session)
        end
    end)
end

-- open the session tab + file panel for a fetched PR and land on the first file
---@param pr { owner: string, repo: string, number: integer }
---@param detail table  -- get_pr result
local function open_session(pr, detail)
    local entries = M.map_files(detail.files)
    if #entries == 0 then
        return notify("no changed files in this pull request")
    end

    -- one panel at a time; opening a PR over an existing session closes it first
    local Panel = require("dipher.panel")
    local existing = Panel.current()
    if existing and existing:is_open() then
        existing:close()
    end

    local cfg = require("dipher").get_config()
    local panel_cfg = cfg.panel or {}
    local title = detail.title or ("#" .. pr.number)
    local return_tab, session_tab = open_session_tab()

    session = {
        coords = { owner = pr.owner, repo = pr.repo },
        pr = pr,
        -- head_sha is captured here; a later slice reads it for expected_head TOCTOU
        pr_meta = {
            base_sha = detail.base_sha,
            head_sha = detail.head_sha,
            head_ref = detail.head_ref,
            url = detail.url,
            title = title,
        },
        root = require("dipher.git").root(vim.fn.getcwd()), -- optional; for jump-to-file
        entries = entries, -- flat FileEntry[] (single section), shared by ref with the panel
        versions = {}, -- per-path blob memo; valid for the session (shas are pinned)
        prefetching = {}, -- paths with an in-flight predictive prefetch (dedupe guard)
        threads = nil, -- PR-wide review threads (§6.4), fetched once by pr.threads.refresh
        thread_collapsed = {}, -- per thread_id collapse override (gc); nil = cursor-driven
        thread_active = nil, -- the anchor key (bufnr:row) the cursor expands (peek)
        view = nil,
        panel = nil,
    }

    -- the pr-only viewed actions, bound on the pr surfaces only (§4.3, §8.2): toggle
    -- on the panel, unviewed nav on both. the generic panel/diff don't own them, so
    -- they reach the buffer via the extra_keymaps seam, not the fixed action set
    local panel_km, diff_km = cfg.keymaps.panel, cfg.keymaps.diff
    local panel_extra = {
        { spec = panel_km.toggle_viewed, fn = toggle_viewed, desc = "toggle viewed" },
        {
            spec = panel_km.next_unviewed,
            fn = function()
                nav_unviewed("next", false)
            end,
            desc = "next unviewed file",
        },
        {
            spec = panel_km.prev_unviewed,
            fn = function()
                nav_unviewed("prev", false)
            end,
            desc = "previous unviewed file",
        },
    }
    -- the diff surface keeps focus in the diff window when stepping (keep_focus = true);
    -- the thread actions (§6.4) also bind here, via the same extra_keymaps seam
    session.diff_extra_keymaps = {
        {
            spec = diff_km.next_unviewed,
            fn = function()
                nav_unviewed("next", true)
            end,
            desc = "next unviewed file",
        },
        {
            spec = diff_km.prev_unviewed,
            fn = function()
                nav_unviewed("prev", true)
            end,
            desc = "previous unviewed file",
        },
        { spec = diff_km.next_thread, fn = M.next_thread, desc = "next review thread" },
        { spec = diff_km.prev_thread, fn = M.prev_thread, desc = "previous review thread" },
        { spec = diff_km.toggle_thread, fn = M.toggle_thread, desc = "toggle thread" },
        { spec = diff_km.resolve_thread, fn = M.resolve, desc = "resolve thread" },
    }

    local panel = Panel.new({
        sections = { { title = ("#%d %s"):format(pr.number, title), entries = entries } },
        root = ("%s/%s"):format(pr.owner, pr.repo),
        footer = detail.url or detail.head_ref,
        keymaps = cfg.keymaps.panel,
        extra_keymaps = panel_extra,
        on_step = on_step,
        listing = panel_cfg.listing,
        position = panel_cfg.position,
        height = panel_cfg.height,
        width = panel_cfg.width,
        progress = panel_cfg.progress,
        on_select = function(entry)
            show_file(entry)
        end,
        on_close = function()
            require("dipher.pr.threads").close_peek() -- drop the split peek float, if open
            if session and session.view and session.view:is_open() then
                session.view:close()
            end
            close_session_tab(session_tab)
            session = nil
        end,
    }):open()
    panel.return_tab = return_tab
    session.panel = panel

    -- auto-select the first file, leaving the cursor in the diff (DiffviewOpen-style)
    panel:select(true)
end

-- M.show(pr): fetch the PR and open its session
---@param pr { owner: string, repo: string, number: integer }
function M.show(pr)
    client.get_pr(pr, function(err, detail)
        if err then
            return notify_err(err)
        end
        open_session(pr, detail)
    end)
end

-- present the list_prs picker. the one transient selector the PR flow still uses
-- (§8.2): a PR list is a genuine pick step with no obvious panel home
---@param coords { owner: string, repo: string }
---@param prs table[]
local function pick(coords, prs)
    vim.ui.select(prs, {
        prompt = "Select a pull request",
        ---@param pr table
        format_item = function(pr)
            local draft = pr.draft and " [draft]" or ""
            return ("#%d %s · @%s %s%s"):format(
                pr.number,
                pr.title,
                pr.author,
                reltime(pr.updated_at),
                draft
            )
        end,
    }, function(choice)
        if not choice then
            return
        end
        M.show({ owner = coords.owner, repo = coords.repo, number = choice.number })
    end)
end

-- M.open(opts): the entry point. resolve coords, then either jump straight to a known
-- PR number or list PRs and pick one
---@param opts { number?: integer, filter?: string, coords?: { owner: string, repo: string } }|nil
function M.open(opts)
    opts = opts or {}
    repo.resolve(opts, function(err, coords)
        if err then
            return notify_err(err)
        end
        if opts.number then
            return M.show({ owner = coords.owner, repo = coords.repo, number = opts.number })
        end
        client.list_prs(coords, opts.filter, function(lerr, prs)
            if lerr then
                return notify_err(lerr)
            end
            if not prs or #prs == 0 then
                return notify("no pull requests for " .. coords.owner .. "/" .. coords.repo)
            end
            pick(coords, prs)
        end)
    end)
end

return M
