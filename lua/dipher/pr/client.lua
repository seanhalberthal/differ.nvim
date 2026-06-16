-- typed wrappers over the generic sidecar request (§7.3). each forwards cb(err,
-- result); no caching or retry here (that lives in Go). the `pr` shorthand is
-- {owner, repo, number}, but the sidecar decodes those fields flat (the handlers
-- embed them, not a nested `pr` object), so every method sends owner/repo/number at
-- the top level. result shapes are fixed by §7.3

local sidecar = require("dipher.sidecar")

local M = {}

-- list_prs result: [{number, title, author, head_ref, updated_at, draft}]
---@param coords { owner: string, repo: string }
---@param filter string|nil  -- open|mine|review_requested (defaults to open)
---@param cb fun(err: table|nil, result: any)
function M.list_prs(coords, filter, cb)
    sidecar.request(
        "list_prs",
        { owner = coords.owner, repo = coords.repo, filter = filter or "open" },
        cb
    )
end

-- get_pr result: {title, body, author, base_sha, head_sha, head_ref, url, state,
-- draft, mergeable, files: [{path, status, additions, deletions, previous_path?,
-- viewed_state}]}
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.get_pr(pr, cb)
    sidecar.request("get_pr", { owner = pr.owner, repo = pr.repo, number = pr.number }, cb)
end

-- get_file_versions result: {base: {content, missing?}, head: {content, missing?},
-- truncated?}. the sidecar fetches `path` at both the base and head refs. pass the
-- pinned `refs` ({base, head} from get_pr) so the sidecar skips the prRefs round-trip
-- and fetches the exact session blobs; omit to let the sidecar resolve them
---@param pr { owner: string, repo: string, number: integer }
---@param path string
---@param refs { base?: string, head?: string }|nil
---@param cb fun(err: table|nil, result: any)
function M.get_file_versions(pr, path, refs, cb)
    refs = refs or {}
    sidecar.request("get_file_versions", {
        owner = pr.owner,
        repo = pr.repo,
        number = pr.number,
        path = path,
        base = refs.base,
        head = refs.head,
    }, cb)
end

-- set_file_viewed result: {viewed_state} (VIEWED|DISMISSED|UNVIEWED). flips the
-- github "Viewed" checkbox for `path` on the PR (§8.2)
---@param pr { owner: string, repo: string, number: integer }
---@param path string
---@param viewed boolean
---@param cb fun(err: table|nil, result: any)
function M.set_file_viewed(pr, path, viewed, cb)
    sidecar.request(
        "set_file_viewed",
        { owner = pr.owner, repo = pr.repo, number = pr.number, path = path, viewed = viewed },
        cb
    )
end

-- get_threads result: [{id, thread_id, path, side, line, start_side?, start_line?,
-- resolved, is_pending, comments:[{id, author, body, created_at}]}]. PR-wide; the
-- frontend keeps it per session and filters to the current file's path when painting
---@param pr { owner: string, repo: string, number: integer }
---@param cb fun(err: table|nil, result: any)
function M.get_threads(pr, cb)
    sidecar.request("get_threads", { owner = pr.owner, repo = pr.repo, number = pr.number }, cb)
end

-- resolve_thread result: {resolved}. `thread_id` is the graphql node id from
-- get_threads; the pr coords are still sent (the sidecar validates them and keys its
-- thread-cache invalidation on them, §7.5)
---@param pr { owner: string, repo: string, number: integer }
---@param thread_id string
---@param resolved boolean
---@param cb fun(err: table|nil, result: any)
function M.resolve_thread(pr, thread_id, resolved, cb)
    sidecar.request("resolve_thread", {
        owner = pr.owner,
        repo = pr.repo,
        number = pr.number,
        thread_id = thread_id,
        resolved = resolved,
    }, cb)
end

return M
