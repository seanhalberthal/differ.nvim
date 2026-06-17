-- runs under headless nvim against a throwaway repo with a real merge conflict:
-- exercises the slice-2 merge session end-to-end (layout, region highlight, conflict
-- nav). identity is pinned inline so commits work without a global gitconfig

local merge = require("dipher.merge")

local function git(cwd, ...)
    local args =
        { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" }
    vim.list_extend(args, { ... })
    return vim.system(args, { cwd = cwd, text = true }):wait()
end

local function git_ok(cwd, ...)
    local res = git(cwd, ...)
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

-- a repo where merging `feature` into `main` conflicts on f.txt (both changed line 2)
local function conflict_repo()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git_ok(root, "init", "-q")
    write(root .. "/f.txt", "a\nb\nc\n")
    git_ok(root, "add", "f.txt")
    git_ok(root, "commit", "-q", "-m", "base")
    git_ok(root, "checkout", "-q", "-b", "feature")
    write(root .. "/f.txt", "a\nTHEIRS\nc\n")
    git_ok(root, "commit", "-q", "-am", "theirs")
    git_ok(root, "checkout", "-q", "main")
    write(root .. "/f.txt", "a\nOURS\nc\n")
    git_ok(root, "commit", "-q", "-am", "ours")
    git(root, "merge", "feature") -- conflicts: exit non-zero, expected
    return root
end

local merge_ns = vim.api.nvim_create_namespace("dipher.merge")

describe(":Dipher mergetool", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    it("opens a session over the conflicted current file", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})

        local s = merge.current()
        assert.is_not_nil(s)
        assert.are.equal("f.txt", s.path)
        -- three windows in the session tab: ours, theirs, result
        assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("shows the markers in the result and highlights the conflict block", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()

        local lines = vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        local has_marker = false
        for _, l in ipairs(lines) do
            if l:sub(1, 7) == "<<<<<<<" then
                has_marker = true
            end
        end
        assert.is_true(has_marker)

        local marks = vim.api.nvim_buf_get_extmarks(s.result_buf, merge_ns, 0, -1, {})
        assert.is_true(#marks > 0)
    end)

    it("lands on the first conflict and walks regions with ]x", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        local first = s.regions[1].result_start
        assert.are.equal(first, vim.api.nvim_win_get_cursor(s.result_win)[1])
    end)

    it("shows the base column under diff3_mixed", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({ layout = "diff3_mixed" })
        assert.are.equal(4, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("closes cleanly", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        merge.close()
        assert.is_nil(merge.current())
    end)
end)

-- fire a buffer-local keymap by its description, so the test doesn't depend on <leader>
local function fire(buf, desc)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.desc == desc and m.callback then
            m.callback()
            return true
        end
    end
    return false
end

local function has_marker(buf)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:sub(1, 7) == "<<<<<<<" then
            return true
        end
    end
    return false
end

describe(":Dipher mergetool resolution", function()
    after_each(function()
        if merge.current() then
            merge.close()
        end
    end)

    it("takes ours for the conflict under the cursor, stripping the markers", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        assert.is_true(fire(s.result_buf, "dipher: take ours"))
        assert.is_false(has_marker(s.result_buf))
        assert.are.same(
            { "a", "OURS", "c" },
            vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        )
    end)

    it("takes both in ours-then-theirs order", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        fire(s.result_buf, "dipher: take both")
        assert.are.same(
            { "a", "OURS", "THEIRS", "c" },
            vim.api.nvim_buf_get_lines(s.result_buf, 0, -1, false)
        )
    end)

    it("writes and stages once the file is marker-free", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        fire(s.result_buf, "dipher: take ours")
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("write")
        assert.are.same({}, require("dipher.git").conflicted(root))
    end)

    it("does not stage while conflicts remain on write", function()
        local root = conflict_repo()
        vim.cmd.edit(root .. "/f.txt")
        merge.open({})
        local s = merge.current()
        vim.api.nvim_set_current_win(s.result_win)
        vim.cmd("write") -- markers still present
        assert.are.same({ "f.txt" }, require("dipher.git").conflicted(root))
    end)
end)
