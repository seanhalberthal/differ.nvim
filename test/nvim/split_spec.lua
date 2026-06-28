-- runs under headless nvim: feeds real vim.text.diff output through the split
-- renderer and asserts both columns stay aligned and each side's map round-trips
local diff = require("differ.model.diff")
local split = require("differ.render.split")
local text_util = require("differ.util.text")

local function build(old_text, new_text)
    return diff.build({
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = old_text,
        new_text = new_text,
    })
end

-- split renders two columns; expose them under old_*/new_* for the assertions
local function render(model, opts)
    local r = split.render(model, opts)
    return {
        old_lines = r.columns[1].lines,
        new_lines = r.columns[2].lines,
        old_map = r.columns[1].map,
        new_map = r.columns[2].map,
    }
end

-- under full context every source line is rendered; from_old/from_new must resolve
-- to a row whose column content matches the source, and the columns stay aligned
local function assert_roundtrip(old_text, new_text)
    local model = build(old_text, new_text)
    local r = render(model, { context = math.huge })
    local old_all = text_util.to_lines(old_text)
    local new_all = text_util.to_lines(new_text)

    assert.are.equal(#r.old_lines, #r.new_lines, "columns must be index-aligned")

    for o = 1, #old_all do
        local row = r.old_map.from_old[o]
        assert(row ~= nil, "old line " .. o .. " unmapped")
        assert.are.equal(old_all[o], r.old_lines[row], "old line " .. o .. " content")
    end
    for n = 1, #new_all do
        local row = r.new_map.from_new[n]
        assert(row ~= nil, "new line " .. n .. " unmapped")
        assert.are.equal(new_all[n], r.new_lines[row], "new line " .. n .. " content")
    end
end

describe("render.split end-to-end round-trip", function()
    it("substitution", function()
        assert_roundtrip("a\nb\nc\nd\ne\n", "a\nb\nC\nd\ne\n")
    end)
    it("insertion", function()
        assert_roundtrip("a\nb\n", "a\nX\nY\nb\n")
    end)
    it("deletion", function()
        assert_roundtrip("a\nb\nc\nd\n", "a\nd\n")
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

    it("renders an aligned placeholder for a binary file", function()
        local r = render(build("a\0b", "c\0d"), { context = math.huge })
        assert.are.same({ "Binary file not shown" }, r.old_lines)
        assert.are.same({ "Binary file not shown" }, r.new_lines)
        assert.are.equal(#r.old_lines, #r.new_lines) -- columns stay row-aligned
    end)
end)
