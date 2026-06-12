local split = require("dipher.render.split")

local FULL = math.huge

local function kinds(map)
    local out = {}
    for i, l in ipairs(map.lines) do
        out[i] = l.kind
    end
    return out
end

describe("render.split substitution", function()
    local model = {
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = "a\nb\nc\nd\ne\n",
        new_text = "a\nb\nC\nd\ne\n",
        hunks = {
            {
                old_start = 3,
                old_count = 1,
                new_start = 3,
                new_count = 1,
                old_lines = { "c" },
                new_lines = { "C" },
            },
        },
    }

    it("lays old and new in aligned columns", function()
        local r = split.render(model, { context = FULL })
        assert.are.same({ "a", "b", "c", "d", "e" }, r.old_lines)
        assert.are.same({ "a", "b", "C", "d", "e" }, r.new_lines)
        assert.are.equal(#r.old_lines, #r.new_lines)
    end)

    it("classifies the changed row as old on the left, new on the right", function()
        local r = split.render(model, { context = FULL })
        assert.are.same({ "context", "context", "old", "context", "context" }, kinds(r.old_map))
        assert.are.same({ "context", "context", "new", "context", "context" }, kinds(r.new_map))
        assert.are.equal(3, r.old_map.lines[3].old)
        assert.are.equal(1, r.old_map.lines[3].hunk)
        assert.are.equal(3, r.new_map.lines[3].new)
    end)

    it("builds per-side reverse indices", function()
        local r = split.render(model, { context = FULL })
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5 }, r.old_map.from_old)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5 }, r.new_map.from_new)
    end)
end)

describe("render.split unequal hunks pad with filler", function()
    it("pads the left column when the new side is longer", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nM\nb\n",
            new_text = "a\nX\nY\nb\n",
            hunks = {
                {
                    old_start = 2,
                    old_count = 1,
                    new_start = 2,
                    new_count = 2,
                    old_lines = { "M" },
                    new_lines = { "X", "Y" },
                },
            },
        }
        local r = split.render(model, { context = FULL })
        assert.are.same({ "a", "M", "", "b" }, r.old_lines)
        assert.are.same({ "a", "X", "Y", "b" }, r.new_lines)
        assert.are.equal(#r.old_lines, #r.new_lines)
        -- the padded left cell is a meta (filler) row carrying no old lnum
        assert.are.equal("meta", r.old_map.lines[3].kind)
        assert.is_nil(r.old_map.lines[3].old)
        assert.are.equal("new", r.new_map.lines[3].kind)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 4 }, r.old_map.from_old)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3, [4] = 4 }, r.new_map.from_new)
    end)

    it("pads the right column when the old side is longer", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nM\nN\nb\n",
            new_text = "a\nX\nb\n",
            hunks = {
                {
                    old_start = 2,
                    old_count = 2,
                    new_start = 2,
                    new_count = 1,
                    old_lines = { "M", "N" },
                    new_lines = { "X" },
                },
            },
        }
        local r = split.render(model, { context = FULL })
        assert.are.same({ "a", "M", "N", "b" }, r.old_lines)
        assert.are.same({ "a", "X", "", "b" }, r.new_lines)
        assert.are.equal("meta", r.new_map.lines[3].kind)
        assert.is_nil(r.new_map.lines[3].new)
    end)
end)

describe("render.split word-level spans", function()
    it("attaches spans to both sides of a positionally paired row", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "local foo = 1\n",
            new_text = "local bar = 1\n",
            hunks = {
                {
                    old_start = 1,
                    old_count = 1,
                    new_start = 1,
                    new_count = 1,
                    old_lines = { "local foo = 1" },
                    new_lines = { "local bar = 1" },
                },
            },
        }
        local r = split.render(model, { context = FULL, deep_diff = { enabled = true } })
        assert.are.same({ { col_start = 6, col_end = 9 } }, r.old_map.lines[1].spans)
        assert.are.same({ { col_start = 6, col_end = 9 } }, r.new_map.lines[1].spans)
    end)
end)

describe("render.split context collapsing", function()
    it("collapses far gaps to an aligned meta row on both sides", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "1\n2\n3\n4\n5\n6\n7\n",
            new_text = "1\nX\n3\n4\n5\n6\n7\n",
            hunks = {
                {
                    old_start = 2,
                    old_count = 1,
                    new_start = 2,
                    new_count = 1,
                    old_lines = { "2" },
                    new_lines = { "X" },
                },
            },
        }
        local r = split.render(model, { context = 1 })
        assert.are.equal(#r.old_lines, #r.new_lines)
        assert.are.equal("meta", r.old_map.lines[#r.old_lines].kind)
        assert.are.equal("meta", r.new_map.lines[#r.new_lines].kind)
    end)
end)

describe("render.split identical content", function()
    it("produces empty columns when there are no hunks", function()
        local r = split.render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nb\n",
            hunks = {},
        }, { context = FULL })
        assert.are.same({}, r.old_lines)
        assert.are.same({}, r.new_lines)
        assert.are.equal(0, r.old_map:len())
        assert.are.equal(0, r.new_map:len())
    end)
end)
