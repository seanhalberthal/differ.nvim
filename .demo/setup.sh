#!/usr/bin/env bash
# build the throwaway git fixtures the demo records against. idempotent: wipes and
# rebuilds both repos each run, with fixed identity + dates so the history reads the
# same every time. checked in; the generated repos under fixture*/ are gitignored.
#
#   bash .demo/setup.sh
#
# produces:
#   .demo/fixture/        normal repo: two tracked files with history + uncommitted
#                         edits (multi-file diff, the s/s staging flow, and log)
#   .demo/fixture-merge/  repo left mid-merge with an unresolved conflict (mergetool)
#   .demo/fixture-pr/     repo with a faked github `origin` remote, so the PR frontend
#                         resolves acme/widgets and talks to the fixture sidecar (no net)
# and builds the demo-only fixture sidecar (.demo/fake-sidecar) the PR scene points at.
set -euo pipefail

demo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$demo_dir/.." && pwd)"
fixture="$demo_dir/fixture"
merge="$demo_dir/fixture-merge"
pr="$demo_dir/fixture-pr"

# isolated git: our own identity, no signing, no global hooks/templates leaking in
git_init() {
	rm -rf "$1"
	mkdir -p "$1"
	git -C "$1" init -q -b main
	git -C "$1" config user.name "differ demo"
	git -C "$1" config user.email "demo@differ.nvim"
	git -C "$1" config commit.gpgsign false
	git -C "$1" config core.hooksPath /dev/null
}

# commit everything in $1 with message $2 on the fixed date $3 (YYYY-MM-DD)
commit() {
	git -C "$1" add -A
	GIT_AUTHOR_DATE="$3T09:00:00" GIT_COMMITTER_DATE="$3T09:00:00" \
		git -C "$1" commit -q -m "$2"
}

# ── fixture/ : two tracked files, history + uncommitted changes ──────────────
git_init "$fixture"
mkdir -p "$fixture/lua"

cat >"$fixture/lua/palette.lua" <<'LUA'
local M = {}

-- named colours used across the ui
M.colours = {
  red = "#f92672",
  green = "#a6e22e",
  blue = "#66d9ef",
}

-- look up a colour by name
function M.hex(name)
  return M.colours[name]
end

return M
LUA
commit "$fixture" "add palette module" 2024-01-08

cat >"$fixture/lua/palette.lua" <<'LUA'
local M = {}

-- named colours used across the ui
M.colours = {
  red = "#f92672",
  green = "#a6e22e",
  blue = "#66d9ef",
}

-- look up a colour by name
function M.hex(name)
  return M.colours[name]
end

-- the colour names, sorted
function M.names()
  local out = {}
  for name in pairs(M.colours) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

return M
LUA
cat >"$fixture/lua/theme.lua" <<'LUA'
local M = {}

M.name = "monokai"

-- background and foreground for the active theme
M.bg = "#272822"
M.fg = "#f8f8f2"

function M.pair()
  return M.bg, M.fg
end

return M
LUA
commit "$fixture" "add names() accessor and theme module" 2024-01-11

cat >"$fixture/README.md" <<'MD'
# palette

A tiny colour-name + theme lookup used by the demo.
MD
commit "$fixture" "document the modules" 2024-01-15

# uncommitted working-tree edits across both files: several distinct hunks to walk,
# stage hunk-by-hunk (the s/s flow), and stage file-by-file from the panel
cat >"$fixture/lua/palette.lua" <<'LUA'
local M = {}

-- named colours used across the ui
M.colours = {
  red = "#f92672",
  green = "#a6e22e",
  blue = "#5fd7ff",
  yellow = "#f4bf75",
}

-- look up a colour by name, falling back to white
function M.hex(name)
  return M.colours[name] or "#f8f8f2"
end

-- the colour names, sorted
function M.names()
  local out = {}
  for name in pairs(M.colours) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

-- how many colours are defined
function M.count()
  return #M.names()
end

return M
LUA
cat >"$fixture/lua/theme.lua" <<'LUA'
local M = {}

M.name = "dracula"

-- background and foreground for the active theme
M.bg = "#282a36"
M.fg = "#f8f8f2"

-- the accent used for highlights
M.accent = "#bd93f9"

function M.pair()
  return M.bg, M.fg
end

return M
LUA

# ── fixture-merge/ : an unresolved merge conflict ────────────────────────────
git_init "$merge"

cat >"$merge/config.lua" <<'LUA'
return {
  theme = "monokai",
  layout = "stacked",

  deep_diff = {
    enabled = true,
    granularity = "word",
  },

  context = 10,
}
LUA
commit "$merge" "initial config" 2024-02-01

git -C "$merge" checkout -q -b feature
cat >"$merge/config.lua" <<'LUA'
return {
  theme = "dracula",
  layout = "split",

  deep_diff = {
    enabled = true,
    granularity = "word",
  },

  context = 20,
}
LUA
commit "$merge" "feature: dracula theme, wider context" 2024-02-03

git -C "$merge" checkout -q main
cat >"$merge/config.lua" <<'LUA'
return {
  theme = "nord",
  layout = "stacked",

  deep_diff = {
    enabled = true,
    granularity = "word",
  },

  context = 3,
}
LUA
commit "$merge" "main: nord theme, tighter context" 2024-02-05

# leave the conflict unresolved; merge exits non-zero, which is the point
GIT_AUTHOR_DATE="2024-02-06T09:00:00" GIT_COMMITTER_DATE="2024-02-06T09:00:00" \
	git -C "$merge" merge feature -m "merge feature" >/dev/null 2>&1 || true

# ── fixture-pr/ : a repo whose github remote the PR frontend resolves ─────────
# the PR diff content comes entirely from the fixture sidecar; this repo exists only
# so the frontend is "inside a git repo" and parse_remote(origin) yields acme/widgets.
# the remote is never contacted, so the url need not exist.
git_init "$pr"
mkdir -p "$pr/lua"
cat >"$pr/lua/theme.lua" <<'LUA'
local M = {}

M.theme = "dracula"
M.context = 20
M.accent = "#bd93f9"

function M.setup()
  M.theme = M.theme or "dracula"
  return M.theme
end

return M
LUA
cat >"$pr/lua/palette.lua" <<'LUA'
local M = {}

M.colours = {
  red = "#ff5555",
  green = "#50fa7b",
  purple = "#bd93f9",
}

return M
LUA
commit "$pr" "feat: add dracula theme" 2024-02-04
git -C "$pr" branch -q -m feat/dracula-theme
git -C "$pr" remote add origin "git@github.com:acme/widgets.git"

# ── fixture sidecar : the demo-only fake the PR scene talks to ────────────────
# built into .demo/fake-sidecar/; .demo/init.lua points sidecar_bin at it. a dot-dir
# package in the main module, so it imports internal/* yet stays out of ./... tooling.
echo "building fixture sidecar"
(cd "$root" && go build -o "$demo_dir/fake-sidecar/fake-sidecar" ./.demo/fake-sidecar)

echo "fixtures built:"
echo "  $fixture"
echo "  $merge"
echo "  $pr  (origin -> acme/widgets)"
echo "  $demo_dir/fake-sidecar/fake-sidecar"
