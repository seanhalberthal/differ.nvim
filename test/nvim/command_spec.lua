-- runs under headless nvim: the :Differ subcommand router. completion is pure
-- string logic; the `panel <pos>` routing drives a live Panel (no git source needed,
-- since Panel.current() tracks any open panel)
local command = require("differ.command")
local Panel = require("differ.panel")

local function fe(path)
    return { path = path, status = "M", additions = 0, deletions = 0 }
end

local function open_panel()
    vim.cmd("silent! only")
    local p = Panel.new({
        sections = { { entries = { fe("a.lua") } } },
        on_select = function() end,
    })
    p:open()
    return p
end

describe("command completion", function()
    it("offers subcommands at position 1", function()
        local out = command.complete("", "Differ ")
        assert.is_true(vim.tbl_contains(out, "panel"))
        assert.is_true(vim.tbl_contains(out, "layout"))
    end)

    it("offers positions under panel", function()
        assert.are.same({ "left", "right", "top", "bottom" }, command.complete("", "Differ panel "))
        assert.are.same({ "left" }, command.complete("l", "Differ panel l"))
    end)

    it("offers the base shortcut at position 1 and under log", function()
        assert.is_true(vim.tbl_contains(command.complete("", "Differ "), "base"))
        assert.are.same({ "base" }, command.complete("", "Differ log "))
    end)
end)

describe("command base shortcut", function()
    it("log base opens range history of <base>...HEAD", function()
        local git = require("differ.git")
        local saved_base, saved_range = git.resolve_base, git.range_history
        local got
        git.resolve_base = function()
            return "origin/main"
        end
        git.range_history = function(opts)
            got = opts
        end
        command.log("base")
        git.resolve_base, git.range_history = saved_base, saved_range
        assert.are.same({ range = "origin/main...HEAD" }, got)
    end)

    it("bare base opens the panel over <base>... (branch vs trunk)", function()
        local git = require("differ.git")
        local saved_base, saved_panel = git.resolve_base, git.panel
        local got
        git.resolve_base = function()
            return "origin/main"
        end
        git.panel = function(opts)
            got = opts
        end
        command.dispatch({ "base" })
        git.resolve_base, git.panel = saved_base, saved_panel
        -- supersede: re-running over a live session reopens (idempotent), like :Differ <rev>
        assert.are.same({ rev = "origin/main...", open_first = true, supersede = true }, got)
    end)

    it("does nothing when no base resolves", function()
        local git = require("differ.git")
        local saved_base, saved_range = git.resolve_base, git.range_history
        local called = false
        git.resolve_base = function()
            return nil
        end
        git.range_history = function()
            called = true
        end
        command.log("base")
        git.resolve_base, git.range_history = saved_base, saved_range
        assert.is_false(called)
    end)
end)

describe("command bare dispatch reroute", function()
    -- stub root + conflicted so the routing is checked without a repo; record which
    -- surface dispatch reaches
    local function run(args, conflicted)
        local git = require("differ.git")
        local merge = require("differ.merge")
        local sr, sc, sp, so = git.root, git.conflicted, git.panel, merge.open
        local routed = {}
        git.root = function()
            return "/repo"
        end
        git.conflicted = function()
            return conflicted
        end
        git.panel = function()
            routed.panel = true
        end
        merge.open = function()
            routed.merge = true
        end
        command.dispatch(args)
        git.root, git.conflicted, git.panel, merge.open = sr, sc, sp, so
        return routed
    end

    it("routes bare :Differ to the merge tool when the tree has conflicts", function()
        local routed = run({}, { "f.txt" })
        assert.is_true(routed.merge)
        assert.is_nil(routed.panel)
    end)

    it("opens the diff panel when there are no conflicts", function()
        local routed = run({}, {})
        assert.is_true(routed.panel)
        assert.is_nil(routed.merge)
    end)

    it("never reroutes :Differ <rev>, even mid-conflict", function()
        local routed = run({ "main..." }, { "f.txt" })
        assert.is_true(routed.panel)
        assert.is_nil(routed.merge)
    end)
end)

describe("command panel", function()
    it("always opens with a file shown (open_first), so there's a diff window", function()
        local git = require("differ.git")
        local saved = git.panel
        local got
        git.panel = function(opts)
            got = opts
        end
        command.panel("")
        git.panel = saved
        assert.is_true(got.open_first)
    end)
end)

describe("command panel position", function()
    it("repositions the live panel", function()
        local p = open_panel()
        command.panel("right")
        assert.are.equal("right", p.position)
        assert.is_true(p:is_open())
        p:close()
    end)

    it("opens at the position when no panel is live", function()
        vim.cmd("silent! only")
        local git = require("differ.git")
        local saved = git.panel
        local got
        git.panel = function(opts)
            got = opts
        end
        command.panel("top")
        git.panel = saved
        -- open_first so a fresh panel always shows a diff (the session anchor)
        assert.are.same({ position = "top", open_first = true }, got)
    end)

    it("treats a non-position arg as a rev spec, not a position", function()
        local p = open_panel()
        local git = require("differ.git")
        local saved = git.panel
        local got
        git.panel = function(opts)
            got = opts
        end
        command.panel("lfet") -- a typo'd position is just a rev spec; panel stays put
        git.panel = saved
        assert.are.equal("bottom", p.position) -- unchanged
        assert.are.equal("lfet", got.rev)
        p:close()
    end)
end)
