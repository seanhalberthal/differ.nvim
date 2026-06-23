-- runs under headless nvim: drives the Panel component through a real window
-- (rendering, selection callback, fold, and the runtime listing/position API).
-- fed plain FileEntry lists (no git), since the panel is source-agnostic
local Panel = require("differ.panel")

local function fe(path, status, add, del)
    return { path = path, status = status or "M", additions = add or 0, deletions = del or 0 }
end

local function lines(p)
    return vim.api.nvim_buf_get_lines(p.bufnr, 0, -1, false)
end

local function panel(entries, opts)
    vim.cmd("silent! only")
    local picked = {}
    local p = Panel.new(vim.tbl_extend("force", {
        sections = { { entries = entries } },
        on_select = function(e)
            picked[#picked + 1] = e
        end,
    }, opts or {}))
    return p, picked
end

describe("panel rendering", function()
    it("renders a folded tree, dirs before files, cursor on first file", function()
        local p = panel({ fe("a.lua"), fe("src/b.lua") })
        p:open()
        assert.are.same({ "▾ src/", " M b.lua", "M a.lua" }, lines(p)) -- one-space indent
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.winid)[1]) -- first file row
        p:close()
    end)

    it("strips a 2+ level common prefix to a header subtitle in tree mode", function()
        local p = panel({ fe("a/b/c/x.lua"), fe("a/b/d/y.lua") }, { root = "/repo" })
        p:open()
        -- "a/b/" is shared and 2 levels deep: stripped, shown as a bare subtitle
        -- line (the helper's section has no title); c/ and d/ become the top dirs
        local body = vim.list_slice(lines(p), 4) -- past the 3-line header
        assert.are.same({ "a/b/", "▾ c/", " M x.lua", "▾ d/", " M y.lua" }, body)
        p:close()
    end)

    it("toggle_listing toggles tree <-> name", function()
        local p = panel({ fe("a.lua"), fe("src/b.lua") })
        p:open()
        p:toggle_listing() -- name: basename-first with a dimmed parent trailer
        assert.are.same({ "M b.lua  ·src/", "M a.lua" }, lines(p))
        p:toggle_listing() -- back to tree
        assert.are.same({ "▾ src/", " M b.lua", "M a.lua" }, lines(p))
        p:close()
    end)
end)

describe("panel navigation", function()
    it("opens the file under the cursor via on_select", function()
        local p, picked = panel({ fe("a.lua"), fe("b.lua") })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 }) -- a.lua
        p:select()
        assert.are.equal("a.lua", picked[1].path)
        p:close()
    end)

    it("]f steps to the next file and opens it", function()
        local p, picked = panel({ fe("a.lua"), fe("b.lua") })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 })
        p:goto_file("next")
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.winid)[1])
        assert.are.equal("b.lua", picked[#picked].path)
        p:close()
    end)

    it("gg / G jump to the first / last file and open it", function()
        local p, picked =
            panel({ fe("a.lua", "M", 1, 0), fe("b.lua", "M", 1, 0), fe("c.lua", "M", 1, 0) })
        p:open()
        p:goto_edge("last")
        assert.are.equal(3, vim.api.nvim_win_get_cursor(p.winid)[1])
        assert.are.equal("c.lua", picked[#picked].path)
        p:goto_edge("first")
        assert.are.equal(1, vim.api.nvim_win_get_cursor(p.winid)[1])
        assert.are.equal("a.lua", picked[#picked].path)
        p:close()
    end)

    it("gg / G skip content-less pure renames at the edges", function()
        -- a.lua and d.lua are pure renames (no hunks); the edge jumps step past them
        -- to the first/last file that actually has a diff, mirroring the initial open
        local p, picked = panel({
            fe("a.lua", "R", 0, 0),
            fe("b.lua", "M", 1, 0),
            fe("c.lua", "M", 0, 2),
            fe("d.lua", "R", 0, 0),
        })
        p:open()
        p:goto_edge("first")
        assert.are.equal("b.lua", picked[#picked].path)
        p:goto_edge("last")
        assert.are.equal("c.lua", picked[#picked].path)
        p:close()
    end)

    it("gg / G still visit untracked files (zero numstat, but real content)", function()
        -- untracked '?' files report 0/0 counts like a pure rename, but they render
        -- their whole content, so the edge jumps must not skip them
        local p, picked = panel({ fe("a.lua", "R", 0, 0), fe("z.lua", "?", 0, 0) })
        p:open()
        p:goto_edge("last")
        assert.are.equal("z.lua", picked[#picked].path)
        p:close()
    end)

    it("gg / G fall back to the absolute edge when every file is content-less", function()
        local p, picked = panel({ fe("a.lua", "R", 0, 0), fe("b.lua", "R", 0, 0) })
        p:open()
        p:goto_edge("first")
        assert.are.equal("a.lua", picked[#picked].path)
        p:goto_edge("last")
        assert.are.equal("b.lua", picked[#picked].path)
        p:close()
    end)

    it("]] / [[ jump between sections, opening each section's first file", function()
        local p, picked = panel({}, {
            sections = {
                { title = "Staged", entries = { fe("a.lua", "M", 1, 0) } },
                { title = "Unstaged", entries = { fe("b.lua", "M", 1, 0) } },
                { title = "Untracked", entries = { fe("z.lua", "?", 0, 0) } },
            },
        })
        p:open()
        p:goto_section("next") -- from Staged -> Unstaged
        assert.are.equal("b.lua", picked[#picked].path)
        p:goto_section("next") -- Unstaged -> Untracked
        assert.are.equal("z.lua", picked[#picked].path)
        p:goto_section("next") -- no further section: stays put
        assert.are.equal("z.lua", picked[#picked].path)
        p:goto_section("prev") -- Untracked -> Unstaged
        assert.are.equal("b.lua", picked[#picked].path)
        p:close()
    end)

    it("]] / [[ are inert in a single-section panel", function()
        local p, picked = panel({ fe("a.lua", "M", 1, 0), fe("b.lua", "M", 1, 0) })
        p:open()
        p:goto_section("next")
        assert.are.equal(0, #picked)
        p:close()
    end)

    it("toggles a directory fold from its row, hiding children", function()
        local p = panel({ fe("src/a.lua"), fe("src/b.lua") })
        p:open()
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 }) -- src/
        p:select() -- dir row => toggle fold
        assert.are.same({ "▸ src/" }, lines(p))
        p:close()
    end)

    it("C collapses every dir, O expands them all", function()
        local p = panel({ fe("src/a.lua"), fe("src/sub/b.lua") })
        p:open()
        p:set_all_folds(true) -- C
        assert.are.same({ "▸ src/" }, lines(p))
        p:set_all_folds(false) -- O
        assert.are.same({ "▾ src/", " ▾ sub/", "  M b.lua", " M a.lua" }, lines(p))
        p:close()
    end)

    it("c on a file closes its parent dir and moves there", function()
        local p = panel({ fe("src/a.lua"), fe("src/sub/b.lua") })
        p:open()
        -- rows: src/(1) sub/(2) b.lua(3) a.lua(4); put the cursor on b.lua
        vim.api.nvim_win_set_cursor(p.winid, { 3, 0 })
        p:close_node()
        assert.are.same({ "▾ src/", " ▸ sub/", " M a.lua" }, lines(p))
        assert.are.equal(2, vim.api.nvim_win_get_cursor(p.winid)[1]) -- moved to sub/
        p:close()
    end)

    it("the file total stays accurate when everything is collapsed", function()
        local winbar = require("differ.ui.winbar")
        local p = panel({ fe("src/a.lua"), fe("src/sub/b.lua") })
        p:open()
        p:set_all_folds(true) -- no file rows visible now
        assert.are.equal(2, p.file_total) -- both files still counted
        vim.g.statusline_winid = p.winid
        vim.api.nvim_win_set_cursor(p.winid, { 1, 0 }) -- on a collapsed dir row
        assert.is_truthy(winbar.panel():find("/2", 1, true)) -- denominator = real total
        vim.g.statusline_winid = nil
        p:close()
    end)
end)

-- the panel window's position relative to the origin window it was split from
local function geom(p)
    local prow, pcol = unpack(vim.api.nvim_win_get_position(p.winid))
    local orow, ocol = unpack(vim.api.nvim_win_get_position(p.origin_win))
    return { prow = prow, pcol = pcol, orow = orow, ocol = ocol }
end

-- per position: which fixed-size flag the split carries, and which edge the panel
-- sits on (left/right compare columns, top/bottom compare rows against the origin)
local PLACEMENT = {
    left = {
        axis = "winfixwidth",
        cmp = function(g)
            return g.pcol < g.ocol
        end,
    },
    right = {
        axis = "winfixwidth",
        cmp = function(g)
            return g.pcol > g.ocol
        end,
    },
    top = {
        axis = "winfixheight",
        cmp = function(g)
            return g.prow < g.orow
        end,
    },
    bottom = {
        axis = "winfixheight",
        cmp = function(g)
            return g.prow > g.orow
        end,
    },
}

describe("panel runtime position", function()
    for _, pos in ipairs({ "left", "right", "top", "bottom" }) do
        it("opens on the " .. pos .. " edge with the right fixed-size flag", function()
            local p = panel({ fe("a.lua") }, { position = pos })
            p:open()
            local spec = PLACEMENT[pos]
            assert.is_true(vim.wo[p.winid][spec.axis])
            assert.is_true(spec.cmp(geom(p)), "wrong edge for " .. pos)
            p:close()
        end)
    end

    it("re-positions live through every edge, keeping one panel + buffer", function()
        local p = panel({ fe("a.lua") })
        p:open()
        local buf, win = p.bufnr, p.winid
        for _, pos in ipairs({ "left", "top", "right", "bottom" }) do
            p:set_position(pos)
            local spec = PLACEMENT[pos]
            assert.is_true(p:is_open(), pos)
            assert.are.equal(buf, p.bufnr) -- same buffer, just re-windowed
            assert.is_false(win == p.winid) -- new window each move
            assert.is_true(vim.wo[p.winid][spec.axis])
            assert.is_true(spec.cmp(geom(p)), "wrong edge for " .. pos)
            win = p.winid
        end
        p:close()
    end)

    it("caps the content column below the window width for top/bottom panels", function()
        -- a top/bottom panel spans the full editor width, so the +/- counts are
        -- pinned to content_width (the configured width), not the far right edge
        local p = panel({ fe("a.lua") }, { position = "bottom", width = 30 })
        p:open()
        local full = vim.api.nvim_win_get_width(p.winid)
        assert.is_true(full > 30, "expected a full-width bottom split")
        assert.are.equal(30, p.content_width)
        p:set_position("right") -- vertical split: content fills the whole window
        assert.are.equal(vim.api.nvim_win_get_width(p.winid), p.content_width)
        p:close()
    end)

    it("current() tracks the open panel and clears on close", function()
        local p = panel({ fe("a.lua") })
        p:open()
        assert.are.equal(p, Panel.current())
        p:close()
        assert.is_nil(Panel.current())
    end)
end)
