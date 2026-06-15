-- the PR frontend session (§8.2, §8.6): pick a PR, list its files in the reused file
-- panel (with a viewed column), and diff each file from the sidecar's base/head
-- blobs. it mirrors git/init.lua's module-local session shape, owning the session
-- tab + panel + the one driven View; the panel and View are source-agnostic, so this
-- only swaps the model source (blobs over IPC) for git's local reads. every sidecar
-- call is async (cb(err, result)); the client already schedules its dispatch

local repo = require("dipher.pr.repo")
local client = require("dipher.pr.client")

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

-- parse a RFC3339 / ISO-8601 timestamp to an epoch for the relative label. coarse
-- buckets mean the local-vs-utc interpretation never shifts the displayed unit
---@param ts string
---@return integer|nil
local function parse_iso(ts)
    local y, mo, d, h, mi, s = ts:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)")
    if not y then
        y, mo, d = ts:match("^(%d+)%-(%d+)%-(%d+)")
        h, mi, s = 0, 0, 0
    end
    if not y then
        return nil
    end
    return os.time({
        year = tonumber(y),
        month = tonumber(mo),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(mi),
        sec = tonumber(s),
        isdst = false,
    })
end

---@param ts string|nil
---@return string
local function reltime(ts)
    if type(ts) ~= "string" or ts == "" then
        return ""
    end
    local epoch = parse_iso(ts)
    if not epoch then
        return ts
    end
    return require("dipher.util.date").relative(epoch)
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
            session.view =
                require("dipher").diff_model(model, { staging = false, can_stage = false })
        end
    end

    local cached = session.versions[entry.path]
    if cached then
        return render(cached)
    end
    -- pass entry.path, not previous_path: the sidecar fetches one path at both refs,
    -- so a rename shows its head content as an add (true rename diffing is a later
    -- sidecar concern; this keeps open-and-navigate correct for the common cases)
    client.get_file_versions(session.pr, entry.path, function(err, vers)
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
        versions = {}, -- per-path blob memo; valid for the session (shas are pinned)
        view = nil,
        panel = nil,
    }

    local panel = Panel.new({
        sections = { { title = ("#%d %s"):format(pr.number, title), entries = entries } },
        root = ("%s/%s"):format(pr.owner, pr.repo),
        footer = detail.url or detail.head_ref,
        keymaps = cfg.keymaps.panel,
        listing = panel_cfg.listing,
        position = panel_cfg.position,
        height = panel_cfg.height,
        width = panel_cfg.width,
        progress = panel_cfg.progress,
        on_select = function(entry)
            show_file(entry)
        end,
        on_close = function()
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
