<div align="center">

# differ.nvim

**your whole diff and review loop in one neovim plugin: local diffs, file history, staging, pr review, and merge conflicts, all with the same UX.**

[![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=flat&logo=lua&logoColor=white)](https://www.lua.org)
[![Go](https://img.shields.io/badge/Go-1.26+-00ADD8?style=flat&logo=go&logoColor=white)](https://go.dev)
[![Neovim](https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat&logo=neovim&logoColor=white)](https://neovim.io)
[![macOS](https://img.shields.io/badge/macOS-supported-6e7681?style=flat&logo=apple&logoColor=white)]()
[![Linux](https://img.shields.io/badge/Linux-supported-6e7681?style=flat&logo=linux&logoColor=white)]()
[![licence](https://img.shields.io/badge/licence-MIT-6366F1?style=flat&logoColor=white)](LICENCE)

[Features](#features) · [Status](#status) · [Installation](#installation) · [Usage](#usage) · [Configuration](#configuration) · [Development](#development)

</div>

---

you can already get most of this from existing plugins, just not all of it in one tool with the same feel. that's what i wanted, so i built it.

everything runs through one renderer, so staging a hunk and replying to a review comment behave like the same tool, because they are. the default view is a stacked dual-rail layout: one scroll surface with old and new lines interleaved per hunk and both line numbers in the gutter. side-by-side is a keystroke away from the same model. word-level highlighting and treesitter syntax are on by default.

the github side runs in a separate process rather than the editor, so opening a pr or posting a review doesn't block on the api, and results are cached between calls.

---

## Status

everything through the merge tool is built and usable: both layouts, the file picker and panel, hunk staging, file history, the full pr-review flow (inline threads, drafts, viewed-state, checks, lifecycle actions), and 3-way conflict resolution.

a live layer on top of the sidecar (optimistic updates, prefetch, warm cache, server-pushed refresh) is on the roadmap, TBD. and it hasn't had broad real-world testing yet, so there may be some rough edges.

---

## Features

- **stacked dual-rail layout.** one scroll surface with old and new lines interleaved per hunk, dual line-number gutter via `statuscolumn`.
- **side-by-side layout** from the same hunk model. switch layout at runtime; it is a pure re-render.
- **pr review in the diff.** inline comment threads, pending-review drafts, thread resolve, per-file viewed-state, ci checks, and lifecycle actions (merge, checkout, ready/draft, close), backed by a go sidecar that owns the github api.
- **file panel and staging.** persistent sidebar with the changed-file tree, status icons, +/- counts, and hunk- and file-level staging.
- **file history.** single-file and branch-range log, walked commit-by-commit, each step a diff through the same engine.
- **3-way merge tool.** base/ours/theirs through the n-column renderer, resolved into the working-tree file.
- **word-level highlighting** and **treesitter syntax** on by default, so the diff reads like source instead of a grey block.
- **real buffer lines** for code. search, yank, and motions all work; the hunk model is canonical and the buffer is a projection of it.
- **one diff engine** (`vim.diff()`, histogram) shared by every source.

---

## Requirements

- Neovim 0.10+ (uses `vim.system`, `vim.fs.relpath`, `vim.diff`)
- git on `PATH`
- a treesitter parser for the languages you diff (optional, for the syntax pass)
- for pr review: the go sidecar (built from this repo) and `gh` authenticated. not needed for local diffs.

---

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "seanhalberthal/differ.nvim",
  config = function()
    require("differ").setup()
  end,
}
```

`setup()` is only needed to change defaults and register highlight groups eagerly. The `:Differ` command is registered on startup either way.

---

## Usage

`:Differ [revspec]` diffs the current file against a resolved source. the grammar mirrors git:

| Command | Diffs |
|---|---|
| `:Differ` | `HEAD` vs worktree (all uncommitted changes) |
| `:Differ <rev>` | `<rev>` vs worktree (changes since `<rev>`) |
| `:Differ <a>..<b>` | `<a>` vs `<b>` (two-dot range) |
| `:Differ <a>...<b>` | merge-base(`<a>`, `<b>`) vs `<b>` |
| `:Differ <a>...` | merge-base(`<a>`, `HEAD`) vs worktree (branch total) |
| `:Differ <a> <b>` | `<a>` vs `<b>` |

### Runtime controls

These re-render the active view only. No refetch, no re-diff, and the state is local to that view.

| Command | Effect |
|---|---|
| `:Differ layout [stacked\|split]` | Set layout; no argument flips it |
| `:Differ context <n>` | Set context lines around hunks |
| `:Differ context full` | Show the whole file |
| `:Differ context +` / `-` | Widen / narrow context by one |

### Keymaps

Buffer-local, active inside a differ diff:

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous hunk |
| `d=` / `d-` | More / less context |

### Lua API

```lua
-- Same as :Differ, for binding keys:
require("differ").open("main...")

-- Render any old/new text pair directly:
require("differ").diff({
  path = "lua/foo.lua",
  old_text = old,
  new_text = new,
  old_rev = "HEAD",
  new_rev = "WORKTREE",
})
```

---

## Configuration

`setup()` merges over these defaults:

```lua
require("differ").setup({
  layout = "stacked",            -- "stacked" | "split", toggleable per-view
  context = 10,                  -- context lines (math.huge = full file)
  deep_diff = {
    enabled = true,
    granularity = "word",        -- "word" | "char"
    similarity_threshold = 0.5,  -- line-pairing cutoff for word-level diffing
  },
  comments = {                   -- pr review threads
    inline = true,
    collapsed = false,
  },
  keymaps = {                    -- one flat action -> lhs table, shared across the diff,
    next_hunk = "]c",            -- panel and history surfaces (each binds what it has).
    prev_hunk = "[c",            -- a value is a string, a list, or false to disable.
    next_file = "]f",            -- override globally here, or scope to one surface via
    prev_file = "[f",            -- a diff = {...} / panel = {...} / history = {...} subtable
    scroll_down = "f",           -- f/b scroll the diff a quarter page (shadow native f/b)
    scroll_up = "b",
    select = { "<CR>", "o" },    -- panel + history
    help = "g?",                 -- panel + history
    stage = "s", unstage = "u", stage_all = "S", unstage_all = "U",  -- diff (hunk) + panel (file)
    more_context = "d=", less_context = "d-",                        -- diff
    discard = "X", refresh = "R",                                    -- panel
    toggle_fold = "za",                                              -- history (range mode)
  },
  relative_dates = false,        -- "3 days ago" instead of YYYY-MM-DD wherever a date shows
  sidecar_bin = nil,             -- override the go sidecar path
})
```

---

## Architecture

A monorepo: a Lua renderer core (`lua/differ/`) and a Go sidecar (`cmd/differ-sidecar/`), so protocol changes land atomically across both. The hunk model is canonical and buffers are projections of it; renderers are pure functions over hunks, which is why a layout toggle is just a re-render.

```
frontends            core (lua/differ)
┌──────────────┐     ┌──────────────────────────────┐
│ local diff   │────▶│  hunk model (canonical)      │
│ (git + diff) │     │  ├─ renderer: stacked        │
├──────────────┤     │  ├─ renderer: side-by-side   │
│ PR review    │────▶│  ├─ word-level highlight pass│
│ (sidecar)    │     │  ├─ syntax pass (treesitter) │
└──────┬───────┘     │  └─ line map (bidirectional) │
       │             └──────────────────────────────┘
       │ JSON over stdio
       ▼
┌──────────────────┐         ┌─────────────┐
│ differ-sidecar   │────────▶│ GitHub API  │
│ (Go, gh auth)    │         │ (REST+GQL)  │
└──────────────────┘         └─────────────┘
```

<details>
<summary>Repository layout</summary>

```
lua/differ/
  init.lua          # setup() + public API (diff / open)
  config.lua        # option defaults and merge
  command.lua       # :Differ subcommand router
  view.lua          # per-view state, windows, in-view keymaps
  model/diff.lua    # hunk model from vim.diff
  render/           # walk, line map, stacked + split renderers
  worddiff/         # tokenizer, line pairing, span computation
  syntax/           # treesitter pass projected through the line map
  ui/               # statuscolumn rail, paint, highlight groups
  git/              # local source: rev-spec grammar + git I/O
cmd/differ-sidecar/ # go github sidecar
test/
  unit/             # pure-Lua busted specs (no Neovim runtime)
  nvim/             # headless-nvim specs (extmark/window assertions)
```

The design lives in `docs/overview.md` and is kept in lock-step with the code.

</details>

---

## Development

```sh
make test        # both suites (unit + headless-nvim)
make test-unit   # pure-Lua unit tests only (busted, no Neovim)
make test-nvim   # headless-nvim tests (needs nlua on PATH)
make lint        # luacheck + stylua --check
make check       # full quality gate
make help        # all targets
```

Modules under `test/unit` must not touch any Neovim or `vim` API, at load or in the functions they test. That is why text splitting is hand-rolled and word-diff fragmenting uses a pure LCS rather than `vim.diff`. Neovim-only behaviour (windows, extmarks, treesitter) is tested in `test/nvim`.

---

## Licence

[MIT](LICENCE)
