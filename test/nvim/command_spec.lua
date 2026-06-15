-- runs under headless nvim: the :Dipher subcommand router. completion is pure
-- string logic; the `panel set` routing drives a live Panel (no git source needed,
-- since Panel.current() tracks any open panel)
local command = require("dipher.command")
local Panel = require("dipher.panel")

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
        local out = command.complete("", "Dipher ")
        assert.is_true(vim.tbl_contains(out, "panel"))
        assert.is_true(vim.tbl_contains(out, "layout"))
    end)

    it("offers 'set' under panel", function()
        assert.are.same({ "set" }, command.complete("", "Dipher panel "))
        assert.are.same({ "set" }, command.complete("s", "Dipher panel s"))
    end)

    it("offers positions under 'panel set'", function()
        assert.are.same(
            { "left", "right", "top", "bottom" },
            command.complete("", "Dipher panel set ")
        )
        assert.are.same({ "left" }, command.complete("l", "Dipher panel set l"))
    end)
end)

describe("command panel", function()
    it("always opens with a file shown (open_first), so there's a diff window", function()
        local git = require("dipher.git")
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

describe("command panel set", function()
    it("repositions the live panel", function()
        local p = open_panel()
        command.panel("set", "right")
        assert.are.equal("right", p.position)
        assert.is_true(p:is_open())
        p:close()
    end)

    it("opens at the position when no panel is live", function()
        vim.cmd("silent! only")
        local git = require("dipher.git")
        local saved = git.panel
        local got
        git.panel = function(opts)
            got = opts
        end
        command.panel("set", "top")
        git.panel = saved
        -- open_first so a fresh panel always shows a diff (the session anchor, §8.1)
        assert.are.same({ position = "top", open_first = true }, got)
    end)

    it("ignores an unknown position", function()
        local p = open_panel()
        command.panel("set", "lfet")
        assert.are.equal("bottom", p.position) -- unchanged
        p:close()
    end)
end)
