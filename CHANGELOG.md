# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Floating keymap cheatsheet (`g?`) on the diff window and the in-review edit window, alongside the panel and history surfaces that already had it. The cheatsheet rows come from the live keymaps, so a configured `lhs` shows correctly, and it lists only the keys actually bound for the active source (staging, edit-in-review, and the session's extra maps such as the PR unviewed nav and thread/comment verbs)
- File-targeted diff verbs from the panel: `de` (go to the real file) and `df` (edit the real file in review) act on the file row under the cursor, opening it first so they operate on it rather than the last-shown diff
- The float help renderer extracted to a shared `differ.ui.help` module reused by the panel, history, and diff surfaces, with a configurable title and one blank row of padding above and below the keymap rows

### Changed

- The staging-review navigation now notifies at the change-set boundary instead of stopping silently. `s`/`u` past the last/first hunk and `S`/`U` past the last/first file echo "no more hunks/files to stage/unstage" when there is nowhere left to step. `step`, `goto_file`, and `step_file` now return whether they actually moved, which the hunk-nav and review callers key off (replacing the old before/after path comparison)
- The diff view now opens one line above the first hunk so the hunk is visible with a line of context, rather than landing directly on it

## [0.1.2] — 2026-06-23

### Added

- Directory and section staging in the panel: `s` / `u` / `X` act on a directory row (every file beneath it, scoped to its section) and on a section-header row (every file in that section). The header case is the only group target when a section's files share a deep prefix the tree strips to a subtitle, leaving no directory row. `S` / `U` stay global
- Panel navigation keymaps: `gg` / `G` jump to the first / last file; `]]` / `[[` step between sections

### Changed

- Pure renames now open instead of reporting "no changes". A rename (`R`/`C` with no content edit) diffs to zero hunks, so selecting one previously never opened; the view now opens for renames and renders the moved file. Initial open (`:Differ`) and edge jumps (`[[` / `]]`) skip content-less renames and land on the first file with a real diff, while untracked files (zero numstat counts but full content) are still visited
- Renamed the GitHub owner to `undont` across the repo, badges, and plugin spec; old paths redirect for a while so existing clones keep working
- Updated the licence copyright holder to `undont`
- Refreshed the README keymaps and added a vhs demo recording

## [0.1.1] — 2026-06-20

### Added

- `command_alias` config (default `nil`): a string or list of strings (e.g. `"D"` or `{ "D", "Df" }`) that registers extra ex-commands routing to the same dispatcher as `:Differ`, so `:D HEAD~1` or `:D log` work. Completion is name-agnostic (keyed off token position), so aliases get full subcommand and rev completion. An invalid name (Vim requires an uppercase-leading user-command name) warns via `vim.notify` rather than aborting setup

## [0.1.0] — 2026-06-20

Initial release. One renderer drives local diffs, file history, staging, PR review, and merge conflicts, so every surface behaves like the same tool.

### Diff engine & rendering

- Stacked dual-rail layout: one scroll surface with old and new lines interleaved per hunk and both line numbers in the gutter via `statuscolumn`
- Side-by-side layout from the same hunk model, switchable at runtime as a pure re-render
- Word-level intra-hunk highlighting rendered as a same-hue background block, with whitespace-only spans dropped and order-aware similarity pairing for word-diff lines
- Treesitter syntax on by default, so a diff reads like source rather than a grey block
- Real buffer lines for code, so search, yank, and motions work; the hunk model is canonical and the buffer is a projection of it
- One diff engine (`vim.diff()`, histogram) shared by every source
- Split rows aligned by similarity, so a mid-hunk insertion opens filler in place
- A full-width cursor-line overlay painted above the diff backgrounds; configurable context expansion (more / less context)

### Command grammar & sessions

- `:Differ [revspec]` with a git-mirroring grammar: bare (`HEAD` vs worktree), `<rev>`, two-dot `<a>..<b>`, three-dot `<a>...<b>` (merge-base), `<a>...` (branch total vs worktree), and `<a> <b>`
- `:Differ base` and `:Differ log base` shortcuts
- `:Differ <rev>` is idempotent: re-opening reopens over a live session
- HEAD re-read per source build, so a branch switch updates the statusline label
- Sessions end when the diff, panel, or compose window is navigated away

### File panel & staging

- Persistent sidebar with the changed-file tree, status icons, +/- counts, and tree / name listing modes
- Hunk-level and file-level staging, with the panel staging at file level and the diff view at hunk level
- Readable at depth: pinned diffstat, name truncation, deep-prefix subtitle, and fold operations
- Panel sidebar toggles in place instead of ending the session; the diffstat stays next to the tree on full-width top/bottom panels
- The diff cursor holds near its hunk across an external refresh

### Edit in review

- Edit the diffed file in place and write it back, with the diff cursor's column carried to the real file on `de` / `df`
- Editing in review is blocked on `<rev>` versus worktree opens (where there is no single writable file)

### File history

- File history for single files and branch ranges, walked commit-by-commit, each step a diff through the same engine
- Concurrent blob fetches and pinned-sha fast paths (pinned shas skip PR refs)

### PR review (Go sidecar)

- A supervised Go sidecar owns the GitHub API: stdio framing, a hello handshake, and restart-backoff supervision, so opening a PR or posting a review doesn't block the editor and results are cached between calls
- PR picker, typed client, and file navigation
- Inline review-thread overlay with thread/comment gestures: `gc` collapse, `]t` / `[t` thread nav, `gr` resolve, and a split-layout peek float showing comment times; the resolved tag sits on the footer rule in green and the peek float hides when focus leaves the diff columns
- Review-authoring loop: pending-review drafts, commenting, submit / discard, delete-comment, and immediate posting that honours the one-pending-review rule; the active draft state shows in the diff winbar
- Per-file viewed-state: `<Tab>` toggle, `]u` / `[u` nav, and neighbour prefetch
- CI checks view and PR lifecycle verbs (merge, checkout, ready / draft, close), grouped by what they act on
- An ISO-8601 timestamp parser for the timeline; a minimal PR overview page and timeline

### 3-way merge tool

- Reads merge-conflict stages and parses conflict markers into a 3-way model, carrying the `|||||||` / `=======` lines and ref labels through the parse
- Lays out the base / ours / theirs columns through the n-column renderer with conflict navigation, locating each side's slab and folding the unchanged spans
- Resolves conflicts in place and writes / stages on save; per-side colour, input sync, and raw editable markers
- Bare `:Differ` routes to the merge tool mid-conflict; result-buffer diagnostics are cleared rather than merely hidden

### Security

- Server-side `expected_head` TOCTOU guard on mutating PR actions

### Tooling & release

- Prefix-driven auto-tagging and release notes, a PR-title check, and version stamping via ldflags
- Build-on-install sidecar via the `make go-build` build hook (no prebuilt binaries)
