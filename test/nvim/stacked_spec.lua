-- Runs under headless nvim: feeds real vim.text.diff output through the renderer
-- and asserts the map round-trips, guarding the hand-built unit fixtures against
-- any drift in the engine's hunk-index convention.
local diff = require("dipher.model.diff")
local stacked = require("dipher.render.stacked")
local text_util = require("dipher.util.text")

local function build(old_text, new_text)
    return diff.build({
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = old_text,
        new_text = new_text,
    })
end

-- Stacked renders a single "unified" column; unwrap it for the assertions.
local function render(model, opts)
    return stacked.render(model, opts).columns[1]
end

-- Under full context every line is rendered, so from_old/from_new must point at a
-- buffer line whose content matches the source line. This is the core map contract.
local function assert_roundtrip(old_text, new_text)
    local model = build(old_text, new_text)
    local r = render(model, { context = math.huge })
    local old_all = text_util.to_lines(old_text)
    local new_all = text_util.to_lines(new_text)

    for o = 1, #old_all do
        local buf = r.map.from_old[o]
        assert(buf ~= nil, "old line " .. o .. " unmapped")
        assert.are.equal(old_all[o], r.lines[buf], "old line " .. o .. " content")
    end
    for n = 1, #new_all do
        local buf = r.map.from_new[n]
        assert(buf ~= nil, "new line " .. n .. " unmapped")
        assert.are.equal(new_all[n], r.lines[buf], "new line " .. n .. " content")
    end
end

describe("render.stacked end-to-end map round-trip", function()
    it("substitution", function()
        assert_roundtrip("a\nb\nc\nd\ne\n", "a\nb\nC\nd\ne\n")
    end)
    it("insertion in the middle", function()
        assert_roundtrip("a\nb\n", "a\nX\nb\n")
    end)
    it("insertion at top and bottom", function()
        assert_roundtrip("a\nb\n", "X\na\nb\nY\n")
    end)
    it("deletion in the middle", function()
        assert_roundtrip("a\nb\nc\n", "a\nc\n")
    end)
    it("delete first and last", function()
        assert_roundtrip("a\nb\nc\n", "b\n")
    end)
    it("add from empty", function()
        assert_roundtrip("", "a\nb\nc\n")
    end)
    it("delete to empty", function()
        assert_roundtrip("a\nb\nc\n", "")
    end)
    it("missing trailing newline", function()
        assert_roundtrip("a\nb\nc", "a\nB\nc")
    end)
    it("multiple separated hunks", function()
        assert_roundtrip("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n")
    end)
end)

describe("render.stacked end-to-end content", function()
    it("renders raw code lines with no decoration", function()
        local model = build("a\nb\nc\n", "a\nB\nc\n")
        local r = render(model, { context = math.huge })
        assert.are.same({ "a", "b", "B", "c" }, r.lines)
    end)

    it("collapses far context into a meta line", function()
        local model = build("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n")
        local r = render(model, { context = 1 })
        local metas = 0
        for _, l in ipairs(r.map.lines) do
            if l.kind == "meta" then
                metas = metas + 1
            end
        end
        assert.are.equal(1, metas)
    end)
end)
