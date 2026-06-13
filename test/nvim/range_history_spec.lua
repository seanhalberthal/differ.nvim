-- runs under headless nvim against a throwaway git repo: exercises branch-range
-- history (§8.4, dp): the range commit walk, per-commit file listing (incl. a root
-- commit), the panel expanding commits to nested files, on_file driving the view,
-- and ]f/[f walking files across commits
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

local V1, V2, V3 = "local x = 1\nreturn x\n", "local x = 2\nreturn x\n", "local x = 3\nreturn x\n"

-- main: commit1 (root: a.lua=V1, b.lua=b1) -> commit2 (a.lua=V2). then a feature
-- branch: commit3 (a.lua=V3 + c.lua added) -> commit4 (b.lua=b2)
local function repo_with_branch()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    write(root .. "/b.lua", "b1\n")
    git(root, "add", "a.lua", "b.lua")
    git(root, "commit", "-q", "-m", "c1: seed")
    write(root .. "/a.lua", V2)
    git(root, "commit", "-q", "-am", "c2: bump a")
    git(root, "checkout", "-q", "-b", "feature")
    write(root .. "/a.lua", V3)
    write(root .. "/c.lua", "c1\n")
    git(root, "add", "a.lua", "c.lua")
    git(root, "commit", "-q", "-m", "c3: edit a, add c")
    write(root .. "/b.lua", "b2\n")
    git(root, "commit", "-q", "-am", "c4: bump b")
    return root
end

local function view_in_origin(h)
    vim.api.nvim_set_current_win(h.origin_win)
    return require("dipher.view").current()
end

describe("git.range_commits / commit_files", function()
    it("lists the range's commits newest first, merges excluded", function()
        local root = repo_with_branch()
        local commits = git_src.range_commits(root, "main..HEAD")
        assert.are.equal(2, #commits)
        assert.are.equal("c4: bump b", commits[1].subject)
        assert.are.equal("c3: edit a, add c", commits[2].subject)
    end)

    it("lists a commit's files with status and counts", function()
        local root = repo_with_branch()
        local commits = git_src.range_commits(root, "main..HEAD")
        local files = git_src.commit_files(root, commits[2].sha) -- c3: edit a, add c
        assert.are.equal(2, #files)
        assert.are.same({ "a.lua", "c.lua" }, { files[1].path, files[2].path })
        assert.are.equal("M", files[1].status)
        assert.are.equal("A", files[2].status)
    end)

    it("lists a root commit's files via the empty tree (pure adds)", function()
        local root = repo_with_branch()
        local first = git(root, "rev-list", "--max-parents=0", "HEAD"):gsub("%s+$", "")
        local files = git_src.commit_files(root, first)
        local by_path = {}
        for _, f in ipairs(files) do
            by_path[f.path] = f.status
        end
        assert.are.equal("A", by_path["a.lua"]) -- the root commit adds everything
        assert.are.equal("A", by_path["b.lua"])
    end)
end)

describe(":Dipher log <range> (branch-range history)", function()
    it("opens an expandable commit panel showing the newest commit's first file", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        assert.is_not_nil(h)
        assert.are.equal("range", h.mode)
        assert.are.equal("main..HEAD", h.lines[1]) -- the range in the header
        -- the newest commit (c4: bump b) is expanded and its file b.lua is open
        local v = view_in_origin(h)
        assert.are.equal("b.lua", v.model.path)
        assert.are.equal("b1\n", v.model.old_text) -- b.lua at the parent
        assert.are.equal("b2\n", v.model.new_text) -- b.lua at c4
        h:close()
    end)

    it("expands a commit to its files and opens the one under the cursor", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        -- expand c3 (commit index 2): cursor on its commit row, then <CR>
        vim.api.nvim_set_current_win(h.winid)
        vim.api.nvim_win_set_cursor(h.winid, { h:_commit_line(2), 0 })
        h:select()
        -- selecting a collapsed commit expands it and opens its first file (a.lua)
        local v = view_in_origin(h)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(V2, v.model.old_text) -- a.lua at c3's parent (c2)
        assert.are.equal(V3, v.model.new_text) -- a.lua at c3

        -- now open c3's second file (c.lua) from its row
        vim.api.nvim_set_current_win(h.winid)
        vim.api.nvim_win_set_cursor(h.winid, { h:_file_line(2, 2), 0 })
        h:select()
        v = view_in_origin(h)
        assert.are.equal("c.lua", v.model.path)
        assert.are.equal("", v.model.old_text) -- newly added in c3
        assert.are.equal("c1\n", v.model.new_text)
        h:close()
    end)

    it("walks files across commit boundaries with ]f / [f", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        -- start: c4's only file b.lua
        assert.are.equal(1, h.index)
        assert.are.equal("b.lua", view_in_origin(h).model.path)

        h:step("next") -- past c4's last file -> auto-expand c3, its first file a.lua
        assert.are.equal(2, h.index)
        assert.are.equal(1, h.file_index)
        assert.are.equal("a.lua", view_in_origin(h).model.path)

        h:step("next") -- c3's second file c.lua
        assert.are.equal("c.lua", view_in_origin(h).model.path)

        h:step("prev") -- back to a.lua
        assert.are.equal("a.lua", view_in_origin(h).model.path)

        h:step("prev") -- back across the boundary to c4's b.lua
        assert.are.equal(1, h.index)
        assert.are.equal("b.lua", view_in_origin(h).model.path)
        h:close()
    end)

    it("toggles a commit's fold with za, hiding its files", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        local function has_file_row(path)
            for _, m in ipairs(h.meta) do
                if m and m.kind == "file" and m.entry.path == path then
                    return true
                end
            end
            return false
        end
        assert.is_true(has_file_row("b.lua")) -- c4 starts expanded
        vim.api.nvim_set_current_win(h.winid)
        vim.api.nvim_win_set_cursor(h.winid, { h:_commit_line(1), 0 })
        h:toggle_fold()
        assert.is_false(has_file_row("b.lua")) -- collapsed
        h:close()
    end)

    it("renders ref decorations on the tip commit", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        -- the tip (c4) carries the feature/HEAD decoration; it should show in its row
        assert.is_truthy(h.commits[1].refs:find("feature", 1, true))
        assert.is_truthy(h.lines[3]:find("feature", 1, true))
        h:close()
    end)

    it("toggles closed on reinvoke and tears down the driven view", function()
        local root = repo_with_branch()
        vim.cmd.edit(root .. "/a.lua")
        git_src.range_history({ range = "main..HEAD" })
        local h = History.current()
        local v = view_in_origin(h)
        assert.is_true(v:is_open())
        git_src.range_history({ range = "main..HEAD" })
        assert.is_nil(History.current())
        assert.is_false(v:is_open())
    end)
end)
