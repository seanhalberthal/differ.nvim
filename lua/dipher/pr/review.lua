-- the pending-review draft lifecycle (§8.2): start/reattach a draft, submit it as one
-- batch with an event, or discard it. while session.review_id is set, comments compose
-- as drafts (pr/comment.lua); submit/discard clear it and return to immediate mode.
-- every mutation carries the session head as expected_head for the §7.5 TOCTOU guard,
-- and reacts to a conflict by refreshing rather than auto-retrying (§11)

local client = require("dipher.pr.client")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- a session is still live (panel open) when an async mutation returns
---@param session table
---@return boolean
local function alive(session)
    return session ~= nil and session.view ~= nil and session.view:is_open()
end

-- re-fetch threads so the overlay reflects a draft/submit/discard authoritatively (the
-- sidecar invalidates its thread cache on each mutation)
---@param session table
local function repaint_threads(session)
    session.threads = nil
    require("dipher.pr.threads").refresh(session)
end

-- a diff column window for the compose split to anchor to (the summary has no line
-- anchor of its own, so it just rides off a visible diff column)
---@param session table
---@return integer|nil
local function diff_win(session)
    for _, col in ipairs((session.view and session.view.columns) or {}) do
        if col.winid and vim.api.nvim_win_is_valid(col.winid) then
            return col.winid
        end
    end
end

-- :Dipher pr review — start (or reattach to) the viewer's pending draft. idempotent in
-- the sidecar, so this never orphans a second draft
---@param session table
function M.start(session)
    if session.review_id then
        return notify("a review is already in progress; comments are drafts")
    end
    client.start_review(session.pr, function(err, res)
        if not alive(session) then
            return
        end
        if err then
            return require("dipher.pr").notify_err(err)
        end
        session.review_id = res and res.review_id
        notify("review started — comments are drafts until you submit")
    end)
end

-- :Dipher pr resume — reattach the current session to its pending draft and jump to a
-- pending comment (position restore, §8.2). a no-op notice when there's no draft
---@param session table
function M.reattach(session)
    client.get_pending_review(session.pr, function(err, res)
        if not alive(session) then
            return
        end
        if err then
            return require("dipher.pr").notify_err(err)
        end
        -- a PR with no draft decodes review_id as null -> vim.NIL (userdata, truthy),
        -- so guard on the string type rather than truthiness
        local review_id = res and res.review_id
        if type(review_id) ~= "string" or review_id == "" then
            return notify("no pending review to resume on this PR")
        end
        session.review_id = review_id
        local first = res.comments and res.comments[1]
        if first then
            require("dipher.pr").goto_anchor({
                path = first.path,
                side = first.side,
                line = first.line,
            })
        end
        notify("resumed your pending review — comments are drafts")
    end)
end

-- :Dipher pr submit — finalise the draft as one batch. pick an event, author a summary
-- in the compose float, then submit with the session head guard. on success the drafts
-- become published (re-fetched) and immediate mode resumes
---@param session table
function M.submit(session)
    if not session.review_id then
        return notify("no active review to submit; start one with :Dipher pr review")
    end
    vim.ui.select({ "COMMENT", "APPROVE", "REQUEST_CHANGES" }, {
        prompt = "Submit review as",
    }, function(event)
        if not event then
            return -- cancelled the pick; nothing submitted
        end
        require("dipher.ui.compose").open({
            title = "Review summary · " .. event,
            layout = session.view and session.view.layout,
            anchor_win = diff_win(session),
            on_submit = function(body)
                M._do_submit(session, event, body)
            end,
        })
    end)
end

---@param session table
---@param event string
---@param body string
function M._do_submit(session, event, body)
    client.submit_review(session.pr, {
        review_id = session.review_id,
        event = event,
        body = body,
        expected_head = session.pr_meta.head_sha,
    }, function(err, _)
        if not alive(session) then
            return
        end
        if err then
            if err.code == "conflict" then
                return require("dipher.pr").handle_conflict(function()
                    notify("re-submit your review against the refreshed head", vim.log.levels.WARN)
                end)
            end
            return require("dipher.pr").notify_err(err)
        end
        session.review_id = nil
        repaint_threads(session)
        notify("review submitted · " .. event)
    end)
end

-- :Dipher pr discard — drop the pending draft and its unsubmitted comments. destructive,
-- so it confirms first; the draft threads then vanish from the overlay
---@param session table
function M.discard(session)
    if not session.review_id then
        return notify("no active review to discard")
    end
    if
        vim.fn.confirm("Discard the pending review and its draft comments?", "&Yes\n&No", 2) ~= 1
    then
        return
    end
    client.discard_review(session.pr, session.review_id, function(err, _)
        if not alive(session) then
            return
        end
        if err then
            return require("dipher.pr").notify_err(err)
        end
        session.review_id = nil
        repaint_threads(session)
        notify("review discarded")
    end)
end

return M
