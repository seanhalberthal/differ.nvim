# manual testing prep (gh sidecar)

the end-to-end pass waits until the lua client lands: the features worth exercising
run through the client (panels, keymaps, thread rendering), not raw stdio. this is
the setup to have ready so the pass is a walk-through, not a scramble. an optional
sidecar-only smoke test (hand-driven JSON over stdio against one real PR) can come
earlier

## accounts

- **main account**: the identity the sidecar authenticates as (resolves `GH_TOKEN`
  / `GITHUB_TOKEN` / `gh auth token`)
- **dummy account**: a second account on its own email, to play author and reviewer
  counterpart. keep a way to switch which token the sidecar sees (a per-shell
  `GH_TOKEN`, or two `gh` profiles)

## test repo (owned by the dummy account)

the dummy owns the repo and the PRs and requests the main account as reviewer, so
the sidecar sees PRs as a reviewer; that's what unlocks `review_requested`, approve
/ request-changes, and resolving another author's threads. add the main account as
a collaborator so it can be requested and can merge

seed:

- an initial commit with a few files: a code file, a file to rename later, a
  binary/image, and a larger file (for the later large-file streaming work)
- a trivial github actions workflow (one passing job, optionally one failing) so
  PRs carry checks for `get_checks`

## PRs to create (the scenarios)

| PR | shape | exercises |
| -- | ----- | --------- |
| varied-diff | multi-commit; files modified + added + deleted + renamed | `get_pr`, `get_file_versions` (each status incl. missing base/head), `get_threads` |
| draft | opened as a draft | `list_prs` draft flag, `set_pr_state` ready/draft |
| mergeable | clean against base | `merge_pr` (squash/merge/rebase), `set_pr_state` close/open |
| conflicting | branch that conflicts with base | `merge_pr` returns `conflict` |
| threads | dummy posts a single-line + a range comment, resolves one, leaves one open, leaves a pending draft review | `get_threads` (resolved/pending/range), `get_pending_review`, `resolve_thread` |
| mine | authored by the main account in the same repo | `list_prs filter=mine`, author-side state changes |

## reviewer wiring

- add the main account as a collaborator on the dummy repo
- request the main account as reviewer on the varied-diff and threads PRs, for
  `list_prs filter=review_requested`

## method coverage

read:

- `list_prs`: open / mine / review_requested; draft flag; head_ref populated on
  every path
- `get_pr`: metadata, file list, rename `previous_path`, per-file `viewed_state`
- `get_file_versions`: modified, added (missing base), deleted (missing head),
  renamed
- `get_threads`: single-line, range (`start_*`), resolved vs open, pending draft
- `get_pending_review`: a draft open, and the null case
- `get_checks`: success / failure / pending rollup, CheckRun + legacy status context

mutate:

- `start_review`: fresh, then again (idempotent, same review_id back)
- `post_comment`: single, range, reply, draft (with review_id) vs immediate
- `submit_review`: APPROVE, REQUEST_CHANGES, COMMENT
- `discard_review`: drops the draft and its comments
- `resolve_thread`: resolve and unresolve
- `set_file_viewed`: viewed and un-viewed
- `merge_pr`: squash/merge/rebase on the mergeable PR, conflict on the other
- `set_pr_state`: ready, draft, closed, open

## once the lua client is in

1. build the sidecar (`make go-build`) and point the plugin at the binary
2. against the dummy repo PRs, run the `:Dipher pr …` commands and walk the
   coverage list through the real UX
3. swap to the dummy's token to exercise the author-only and counterpart actions the
   main account can't perform on its own PRs

### slice 1 — picker + file navigation

from inside the test repo's worktree:

- `:Dipher pr` lists the open PRs in the picker, each row `#<n> <title> · @<author>
  <relative time>`, drafts marked `[draft]`; selecting one opens the session tab
- `:Dipher pr <n>` skips the picker and opens that PR directly
- `:Dipher pr <owner>/<repo>#<n>` targets a fork / another repo (the §1 override)
- the panel lists the PR's files with a `[x]`/`[ ]` viewed column (viewed files
  dimmed); the first file auto-opens in the diff with base/head as the rev labels
- added file → base side empty; deleted file → head side empty; modified → both
- `]f`/`[f` step files, re-sourcing the one diff in place (no new windows); revisits
  are instant (the per-session blob memo)
- `:Dipher close` tears the session down and returns to the invoking tab
- error paths surface one notification: no token (`gh auth login`), no gh
  (`install gh or set GH_TOKEN`), a non-github remote (`not a github remote`)
