-- :Dipher subcommand router. phase 1 wires the runtime view controls (§8.3);
-- diff/pr/log/mergetool subcommands arrive with their frontends (phases 2+)

local View = require("dipher.view")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- :Dipher layout [stacked|split], no arg flips the current view's layout
---@param arg string|nil
function M.layout(arg)
    local view = View.current()
    if not view then
        return notify("no diff view here", vim.log.levels.WARN)
    end
    if arg == nil or arg == "" then
        view:toggle_layout()
    elseif arg == "stacked" or arg == "split" then
        view:set_layout(arg)
    else
        notify("layout: expected 'stacked' or 'split'", vim.log.levels.ERROR)
    end
end

-- :Dipher context <n|full|+|->, sets/adjusts the per-view context lines
---@param arg string|nil
function M.context(arg)
    local view = View.current()
    if not view then
        return notify("no diff view here", vim.log.levels.WARN)
    end
    if arg == "full" then
        view:set_context(math.huge)
    elseif arg == "+" then
        view:adjust_context(1)
    elseif arg == "-" then
        view:adjust_context(-1)
    else
        local n = tonumber(arg)
        if not n then
            return notify("context: expected a number, 'full', '+' or '-'", vim.log.levels.ERROR)
        end
        view:set_context(math.max(0, math.floor(n)))
    end
end

---@type table<string, true>
local PANEL_POSITIONS = { left = true, right = true, top = true, bottom = true }

-- :Dipher panel [left|right|top|bottom|revspec], open the file panel (§8.6) over a
-- change set and show the first file's diff (the diff window is the session anchor,
-- so there's never a panel without one). on a live session it hides/shows the sidebar
-- in place; `:Dipher close` ends the session. a position word repositions a live panel,
-- reveals a hidden sidebar there, or opens one at that edge when no session exists
-- (height/width carry over from config); any other arg is a rev spec
---@param arg string|nil
function M.panel(arg)
    if arg and PANEL_POSITIONS[arg] then
        local panel = require("dipher.panel").current()
        if panel then
            panel:set_position(arg) -- records position; repositions live if shown
            if not panel:is_open() then
                panel:show() -- hidden sidebar: reveal it at the new position
            end
            return
        end
        return require("dipher.git").panel({ position = arg, open_first = true })
    end
    require("dipher.git").panel({ rev = (arg ~= "" and arg) or nil, open_first = true })
end

-- :Dipher pr [number|owner/repo#number|list [filter]] (§8.2). no arg or a bare
-- number opens the picker / that PR; `owner/repo#number` targets a specific repo
-- (forks, §1); `list [filter]` opens the picker with a filter; `resolve` toggles the
-- review thread under the cursor (§6.4). the review/submit/… sub-verbs arrive later
---@param verb string|nil
---@param arg string|nil
function M.pr(verb, arg)
    local pr = require("dipher.pr")
    if verb == nil or verb == "" or tonumber(verb) then
        return pr.open({ number = verb and tonumber(verb) or nil })
    end
    -- explicit override: owner/repo#number targets a specific repo (forks, §1)
    local owner, repo, num = verb:match("^([^/]+)/([^#]+)#(%d+)$")
    if owner then
        return pr.open({ coords = { owner = owner, repo = repo }, number = tonumber(num) })
    end
    local dispatch = {
        list = function()
            pr.open({ filter = arg or "open" })
        end,
        -- cursor-context: resolve/unresolve the thread under the cursor in the diff (§6.4)
        resolve = function()
            pr.resolve()
        end,
        -- the file-entry verbs (§8.2): view enters the diff read-only, review enters +
        -- starts a review. a number opens that PR fresh; no number reuses the active
        -- session (review with no number starts a draft on it)
        view = function()
            pr.view({ number = arg and tonumber(arg) })
        end,
        -- the review-authoring loop (§8.2): start a draft, submit/discard it, resume a
        -- pending draft, or reply to the thread under the cursor
        review = function()
            pr.review({ number = arg and tonumber(arg) })
        end,
        -- refocus the overview home (the PR landing page) from within the file diff
        overview = function()
            pr.overview()
        end,
        submit = function()
            pr.submit()
        end,
        discard = function()
            pr.discard_review()
        end,
        resume = function()
            pr.resume(arg)
        end,
        reply = function()
            pr.reply()
        end,
        delete = function()
            pr.delete_comment()
        end,
        -- the read-only CI checks view (§8.2)
        checks = function()
            pr.checks()
        end,
        -- lifecycle (§8.2): merge takes an optional method; ready/draft/close/reopen map
        -- to a set_pr_state value; checkout/browser/url stay client-side (§7.3)
        merge = function()
            pr.merge(arg)
        end,
        checkout = function()
            pr.checkout()
        end,
        ready = function()
            pr.set_state("ready")
        end,
        draft = function()
            pr.set_state("draft")
        end,
        close = function()
            pr.set_state("close")
        end,
        reopen = function()
            pr.set_state("reopen")
        end,
        browser = function()
            pr.browser()
        end,
        url = function()
            pr.url()
        end,
    }
    local h = dispatch[verb]
    if h then
        return h()
    end
    notify("unknown `pr` subcommand: " .. verb, vim.log.levels.WARN)
end

-- :Dipher close: end the active session. a live PR session (the pre-review overview
-- page, which has no panel for git.close to catch, or the review proper) ends through
-- its own teardown; otherwise close the local git diff session
function M.close()
    local pr = require("dipher.pr")
    if pr.current_session() then
        return pr.end_session()
    end
    require("dipher.git").close()
end

-- :Dipher log [arg]: file history (§8.4). no arg or an arg naming a readable file →
-- single-file history (that file, else the current buffer); `base` is the trunk
-- shortcut → branch-range history of `<base>...HEAD`; any other arg is a rev-range
---@param arg string|nil
function M.log(arg)
    if arg == "base" then
        local base = require("dipher.git").resolve_base()
        if not base then
            return
        end
        return require("dipher.git").range_history({ range = base .. "...HEAD" })
    end
    if arg and arg ~= "" and vim.fn.filereadable(vim.fn.fnamemodify(arg, ":p")) == 0 then
        return require("dipher.git").range_history({ range = arg })
    end
    require("dipher.git").history({ path = (arg ~= "" and arg) or nil })
end

-- :Dipher gofile: jump from the diff to the real file at the cursor's mapped line
function M.gofile()
    require("dipher").jump_to_file()
end

-- :Dipher edit: edit-in-review (§8.1) — open the real worktree file in a transient
-- editable window at the cursor's mapped line, keeping the diff session live
function M.edit()
    require("dipher").edit_file()
end

-- :Dipher sidecar [stop]: smoke-check the Go sidecar (start + hello round trip,
-- report the binary version), or stop the supervised process
---@param arg string|nil
function M.sidecar(arg)
    local sidecar = require("dipher.sidecar")
    if arg == "stop" then
        sidecar.stop()
        return notify("sidecar stopped")
    end
    sidecar.ping(function(err, info)
        if err then
            return notify("sidecar: " .. (err.message or err.code), vim.log.levels.ERROR)
        end
        notify(
            ("sidecar ok — binary %s, protocol %d"):format(info.binary or "?", info.protocol or 0)
        )
    end)
end

-- :Dipher cache clear: flush the sidecar's in-process caches (§7.5)
---@param arg string|nil
function M.cache(arg)
    if arg ~= "clear" then
        return notify("cache: expected 'clear'", vim.log.levels.ERROR)
    end
    require("dipher.sidecar").request("cache_clear", nil, function(err)
        if err then
            return notify("cache clear: " .. (err.message or err.code), vim.log.levels.ERROR)
        end
        notify("sidecar cache cleared")
    end)
end

---@type table<string, fun(arg: string|nil)>
local SUB = {
    layout = M.layout,
    context = M.context,
    panel = M.panel,
    pr = M.pr,
    close = M.close,
    gofile = M.gofile,
    edit = M.edit,
    log = M.log,
    sidecar = M.sidecar,
    cache = M.cache,
}

-- route `:Dipher ...`. a recognised subcommand (layout/context/panel) takes its
-- arg; `base` is the trunk shortcut → the whole branch vs base (`<base>...`, incl.
-- uncommitted); anything else, including no args, is a local-diff rev spec (§8.1),
-- so `:Dipher`, `:Dipher main...`, `:Dipher a..b` open the file panel over that
-- change set and show the first file's diff (DiffviewOpen-style)
---@param fargs string[]
function M.dispatch(fargs)
    local handler = fargs[1] and SUB[fargs[1]]
    if handler then
        return handler(fargs[2], fargs[3])
    end
    if fargs[1] == "base" then
        local base = require("dipher.git").resolve_base()
        if not base then
            return
        end
        return require("dipher.git").panel({
            rev = base .. "...",
            open_first = true,
            supersede = true,
        })
    end
    -- `:Dipher <rev>` is idempotent: re-running it over a live session opens the new diff
    -- and closes the previous one (supersede), rather than toggling the sidebar
    require("dipher.git").panel({ rev = fargs, open_first = true, supersede = true })
end

---@type table<string, string[]>
local VALUES = {
    layout = { "stacked", "split" },
    context = { "full", "+", "-" },
    panel = { "left", "right", "top", "bottom" },
    -- later slices implement these sub-verbs; listing now keeps completion stable
    pr = {
        "list",
        "view",
        "overview",
        "delete",
        "resolve",
        "reply",
        "review",
        "submit",
        "discard",
        "resume",
        "checks",
        "merge",
        "checkout",
        "ready",
        "draft",
        "close",
        "reopen",
        "browser",
        "url",
    },
    sidecar = { "stop" },
    cache = { "clear" },
    log = { "base" },
}

-- third-level completion: a sub-verb's own argument values, keyed by subcommand then
-- verb. `pr merge` takes a merge method (§8.2)
---@type table<string, table<string, string[]>>
local NESTED = {
    pr = {
        merge = { "squash", "merge", "rebase" },
    },
}

-- completion: subcommands at token 2, that subcommand's value set at token 3, and a
-- verb's own argument values at token 4 (e.g. `:Dipher pr merge <method>`). the token
-- being completed is the last part when arglead is non-empty, else the next one
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
    local parts = vim.split(vim.trim(cmdline), "%s+")
    -- parts[1] == "Dipher"; the index of the token under completion
    local idx = arglead ~= "" and #parts or (#parts + 1)
    local pool
    if idx <= 2 then
        pool = vim.tbl_keys(SUB)
        pool[#pool + 1] = "base" -- the trunk diff shortcut isn't a SUB handler
    elseif idx == 3 then
        pool = VALUES[parts[2]] or {}
    else
        pool = (NESTED[parts[2]] or {})[parts[3]] or {}
    end
    return vim.tbl_filter(function(c)
        return c:find(arglead, 1, true) == 1
    end, pool)
end

return M
