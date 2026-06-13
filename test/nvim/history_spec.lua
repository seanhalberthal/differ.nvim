-- runs under headless nvim against a throwaway git repo: exercises single-file
-- history (§8.4) end-to-end: the log walk, the history panel driving one View per
-- commit (commit vs its parent), commit stepping, the root-commit add edge, and
-- session teardown
local git_src = require("dipher.git")
local History = require("dipher.history")

local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
    assert(
        res.code == 0,
        "git failed: " .. table.concat({ ... }, " ") .. "\n" .. (res.stderr or "")
    )
    return res.stdout
end

local function write(path, content)
    local fd = assert(io.open(path, "wb"))
    fd:write(content)
    fd:close()
end

local V1 = "local x = 1\nreturn x\n"
local V2 = "local x = 2\nreturn x\n"
local V3 = "local x = 3\nreturn x\n"

-- a repo with three commits to a.lua (V1 -> V2 -> V3), each its own commit
local function repo_with_history()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "v1: seed")
    write(root .. "/a.lua", V2)
    git(root, "commit", "-q", "-am", "v2: bump to 2")
    write(root .. "/a.lua", V3)
    git(root, "commit", "-q", "-am", "v3: bump to 3")
    return root
end

-- the History panel returns focus to the diff by default, so the View lives in the
-- origin window (View.current keys off the focused buffer)
local function view_in_origin(h)
    vim.api.nvim_set_current_win(h.origin_win)
    return require("dipher.view").current()
end

describe("git.log_commits", function()
    it("lists a file's commits newest first with parsed fields", function()
        local root = repo_with_history()
        local commits = git_src.log_commits(root, { path = "a.lua" })
        assert.are.equal(3, #commits)
        assert.are.equal("v3: bump to 3", commits[1].subject)
        assert.are.equal("v2: bump to 2", commits[2].subject)
        assert.are.equal("v1: seed", commits[3].subject)
        assert.are.equal(40, #commits[1].sha)
        assert.is_truthy(commits[1].date:match("^%d%d%d%d%-%d%d%-%d%d$"))
    end)

    it("returns an empty list for a path with no history", function()
        local root = repo_with_history()
        assert.are.same({}, git_src.log_commits(root, { path = "nope.lua" }))
    end)
end)

describe(":Dipher log (single-file history)", function()
    it("opens the history panel and the newest commit's diff", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")

        git_src.history({})
        local h = History.current()
        assert.is_not_nil(h)
        assert.is_true(h:is_open())
        -- one row per commit, header lines first
        assert.are.equal(3, #h.commits)
        -- newest commit selected: V2 (its parent) vs V3
        local v = view_in_origin(h)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(V2, v.model.old_text)
        assert.are.equal(V3, v.model.new_text)
        h:close()
    end)

    it("steps to an older commit and re-sources the same view in place", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local diff_buf = vim.api.nvim_win_get_buf(h.origin_win)

        h:step("next") -- next = older: v2 (parent v1) vs v2
        local v = view_in_origin(h)
        assert.are.equal(V1, v.model.old_text)
        assert.are.equal(V2, v.model.new_text)
        -- same window + buffer: re-sourced, not a new view
        assert.are.equal(diff_buf, vim.api.nvim_win_get_buf(h.origin_win))
        h:close()
    end)

    it("renders the root commit as a pure add (no parent)", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        h:step("next") -- v2
        h:step("next") -- v1, the root commit
        local v = view_in_origin(h)
        assert.are.equal("", v.model.old_text) -- parent doesn't resolve -> empty old side
        assert.are.equal(V1, v.model.new_text)
        h:close()
    end)

    it("clamps stepping at the ends of the history", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        assert.are.equal(1, h.index)
        h:step("prev") -- already newest; clamped
        assert.are.equal(1, h.index)
        h:step("next")
        h:step("next")
        h:step("next") -- only three commits; clamped at the oldest
        assert.are.equal(3, h.index)
        h:close()
    end)

    it("steps commits via ]f / [f from inside the diff window", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local v = view_in_origin(h)
        assert.are.equal(V3, v.model.new_text) -- newest

        v:step_file("next") -- no file panel open -> drives the history walk
        assert.are.equal(h.origin_win, vim.api.nvim_get_current_win()) -- focus kept in the diff
        assert.are.equal(2, h.index)
        assert.are.equal(V2, require("dipher.view").current().model.new_text)
        h:close()
    end)

    it("targets an explicit path argument", function()
        local root = repo_with_history()
        write(root .. "/b.lua", "first\n")
        git(root, "add", "b.lua")
        git(root, "commit", "-q", "-m", "add b")
        vim.cmd.edit(root .. "/a.lua") -- editing a.lua, but ask for b.lua's history

        git_src.history({ path = root .. "/b.lua" })
        local h = History.current()
        assert.are.equal(1, #h.commits)
        assert.are.equal("add b", h.commits[1].subject)
        h:close()
    end)

    it("toggles closed when reinvoked and tears down the driven view", function()
        local root = repo_with_history()
        vim.cmd.edit(root .. "/a.lua")
        git_src.history({})
        local h = History.current()
        local v = view_in_origin(h)
        assert.is_true(v:is_open())

        git_src.history({}) -- reinvoke: closes the open session
        assert.is_nil(History.current())
        assert.is_false(v:is_open())
    end)
end)
