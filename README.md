<div align="center">

# dipher.nvim

**A Neovim diff viewer with a stacked dual-rail layout alongside side-by-side, word-level highlighting, and treesitter syntax.**

[![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=flat&logo=lua&logoColor=white)](https://www.lua.org)
[![Go](https://img.shields.io/badge/Go-1.26+-00ADD8?style=flat&logo=go&logoColor=white)](https://go.dev)
[![Neovim](https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat&logo=neovim&logoColor=white)](https://neovim.io)
[![macOS](https://img.shields.io/badge/macOS-supported-6e7681?style=flat&logo=apple&logoColor=white)]()
[![Linux](https://img.shields.io/badge/Linux-supported-6e7681?style=flat&logo=linux&logoColor=white)]()
[![licence](https://img.shields.io/badge/licence-MIT-6366F1?style=flat&logoColor=white)](LICENCE)

[Features](#features) · [Status](#status) · [Installation](#installation) · [Usage](#usage) · [Configuration](#configuration) · [Development](#development)

</div>

---

dipher renders local git diffs and (eventually) GitHub PR reviews through one Lua engine. The bet is a single renderer core with a bidirectional line map, fed by interchangeable sources, so every diff shares one render path. It targets the diffview + octo workflows it replaces, not a cut-down version of them.

---

## Status

dipher is in early development and not ready to daily-drive.

The rendering core is done: local diffs render in both layouts with word-level highlights and treesitter syntax, and the git source layer is wired so `:Dipher` diffs the current file. The changed-file picker, file panel, staging, history, and the entire PR-review side are not built yet. See the [roadmap](#roadmap).

---

## Features

- **Stacked dual-rail layout.** One scroll surface with old and new lines interleaved per hunk, dual line-number gutter via `statuscolumn`.
- **Side-by-side layout** from the same hunk model. Switch layout at runtime; it is a pure re-render.
- **Word-level highlighting.** Sub-line emphasis on the tokens that actually changed, delta-style.
- **Treesitter syntax** projected through the line map, so the diff reads like source instead of a grey block.
- **Real buffer lines** for code. Search, yank, and motions all work; the hunk model is canonical and the buffer is a projection of it.
- **One diff engine** (`vim.diff()`, histogram) shared by every source.

---

## Requirements

- Neovim 0.10+ (uses `vim.system`, `vim.fs.relpath`, `vim.diff`)
- git on `PATH`
- A treesitter parser for the languages you diff (optional, for the syntax pass)

The Go sidecar is a later phase and is not needed for local diffs.

---

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "seanhalberthal/dipher.nvim",
  config = function()
    require("dipher").setup()
  end,
}
```

`setup()` is only needed to change defaults and register highlight groups eagerly. The `:Dipher` command is registered on startup either way.

---

## Usage

`:Dipher [revspec]` diffs the current file against a resolved source. The grammar mirrors git and diffview:

| Command | Diffs |
|---|---|
| `:Dipher` | `HEAD` vs worktree (all uncommitted changes) |
| `:Dipher <rev>` | `<rev>` vs worktree (changes since `<rev>`) |
| `:Dipher <a>..<b>` | `<a>` vs `<b>` (two-dot range) |
| `:Dipher <a>...<b>` | merge-base(`<a>`, `<b>`) vs `<b>` |
| `:Dipher <a>...` | merge-base(`<a>`, `HEAD`) vs worktree (branch total) |
| `:Dipher <a> <b>` | `<a>` vs `<b>` |

### Runtime controls

These re-render the active view only. No refetch, no re-diff, and the state is local to that view.

| Command | Effect |
|---|---|
| `:Dipher layout [stacked\|split]` | Set layout; no argument flips it |
| `:Dipher context <n>` | Set context lines around hunks |
| `:Dipher context full` | Show the whole file |
| `:Dipher context +` / `-` | Widen / narrow context by one |

### Keymaps

Buffer-local, active inside a dipher diff:

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous hunk |
| `d=` / `d-` | More / less context |

### Lua API

```lua
-- Same as :Dipher, for binding keys:
require("dipher").open("main...")

-- Render any old/new text pair directly:
require("dipher").diff({
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
require("dipher").setup({
  layout = "stacked",            -- "stacked" | "split", toggleable per-view
  context = 3,                   -- context lines (math.huge = full file)
  deep_diff = {
    enabled = true,
    granularity = "word",        -- "word" | "char"
    similarity_threshold = 0.5,  -- line-pairing cutoff for word-level diffing
  },
  comments = {                   -- PR review threads (later phase)
    inline = true,
    collapsed = false,
  },
  sidecar_bin = nil,             -- override the Go sidecar path (later phase)
})
```

---

## Architecture

A monorepo: a Lua renderer core (`lua/dipher/`) and a Go sidecar (`cmd/dipher-sidecar/`), so protocol changes land atomically across both. The hunk model is canonical and buffers are projections of it; renderers are pure functions over hunks, which is why a layout toggle is just a re-render.

```
frontends            core (lua/dipher)
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
│ dipher-sidecar   │────────▶│ GitHub API  │
│ (Go, gh auth)    │         │ (REST+GQL)  │
└──────────────────┘         └─────────────┘
```

<details>
<summary>Repository layout</summary>

```
lua/dipher/
  init.lua          # setup() + public API (diff / open)
  config.lua        # option defaults and merge
  command.lua       # :Dipher subcommand router
  view.lua          # per-view state, windows, in-view keymaps
  model/diff.lua    # hunk model from vim.diff
  render/           # walk, line map, stacked + split renderers
  worddiff/         # tokenizer, line pairing, span computation
  syntax/           # treesitter pass projected through the line map
  ui/               # statuscolumn rail, paint, highlight groups
  git/              # local source: rev-spec grammar + git I/O
cmd/dipher-sidecar/ # Go GitHub sidecar (later phase)
test/
  unit/             # pure-Lua busted specs (no Neovim runtime)
  nvim/             # headless-nvim specs (extmark/window assertions)
```

The design lives in `docs/overview.md` and is kept in lock-step with the code.

</details>

---

## Roadmap

Each phase ships independently. Phases 1 and 2 alone replace daily diffview use.

| Phase | Deliverable |
|---|---|
| 1 | Core: hunk model, both renderers, line map, gutter rail, hunk nav, word-level highlighting, treesitter syntax |
| 2 | Local frontend: git sources, file picker, file panel, hunk staging, file history |
| 3 | Go sidecar: protocol, v1 GitHub methods, caching, supervised Lua client |
| 4 | PR review: picker, viewed-state, inline comment threads, draft reviews, thread resolve, checks, lifecycle actions |
| 5 | 3-way merge tool: N-column renderer, editable result buffer, take ours / theirs / both |
| 6 | Live layer: optimistic updates, prefetch, warm cache, server-pushed overlay refresh, large-file streaming |

---

## Development

```sh
make test        # pure-Lua unit tests (busted, no Neovim)
make test-nvim   # headless-nvim tests (needs nlua on PATH)
make lint        # luacheck + stylua --check
make check       # full quality gate
make help        # all targets
```

Modules under `test/unit` must not touch any Neovim or `vim` API, at load or in the functions they test. That is why text splitting is hand-rolled and word-diff fragmenting uses a pure LCS rather than `vim.diff`. Neovim-only behaviour (windows, extmarks, treesitter) is tested in `test/nvim`.

---

## Licence

[MIT](LICENCE)
