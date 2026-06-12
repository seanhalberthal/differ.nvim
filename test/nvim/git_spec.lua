-- Runs under headless nvim against a throwaway git repo: exercises the local git
-- source end-to-end — content reads, changed-file listing, merge-base resolution,
-- and :Dipher open building a correct DiffModel for the current file.
local git_src = require("dipher.git")
local rev = require("dipher.git.rev")

-- Run git in `cwd`, asserting success. Identity is pinned inline so commits work
-- in CI without a global gitconfig.
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

-- A fresh repo with one committed file (a.lua = V1) on `main`.
local V1 = "local x = 1\nreturn x\n"
local function fresh_repo()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    git(root, "init", "-q")
    write(root .. "/a.lua", V1)
    git(root, "add", "a.lua")
    git(root, "commit", "-q", "-m", "init")
    return root
end

describe("git.read / changed_files", function()
    it("reads the committed version and the worktree version", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n") -- uncommitted edit

        local head = { kind = "rev", rev = "HEAD", label = "HEAD" }
        local wt = { kind = "worktree", label = "WORKTREE" }
        assert.are.equal(V1, git_src.read(head, root, "a.lua"))
        assert.are.equal("local x = 2\nreturn x\n", git_src.read(wt, root, "a.lua"))
    end)

    it("returns nil for a path absent on a side (add/delete)", function()
        local root = fresh_repo()
        local head = { kind = "rev", rev = "HEAD", label = "HEAD" }
        assert.is_nil(git_src.read(head, root, "never.lua"))
    end)

    it("lists changed files for the default uncommitted source", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        local files = git_src.changed_files(rev.source({}), root)
        assert.are.same({ { status = "M", path = "a.lua" } }, files)
    end)
end)

describe(":Dipher open", function()
    it("diffs the current file: HEAD vs worktree by default", function()
        local root = fresh_repo()
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        vim.cmd.edit(root .. "/a.lua")

        local v = git_src.open({})
        assert.is_not_nil(v)
        assert.are.equal("a.lua", v.model.path)
        assert.are.equal(V1, v.model.old_text)
        assert.are.equal("local x = 2\nreturn x\n", v.model.new_text)
        v:close()
    end)

    it("resolves a merge-base (three-dot) against the working tree", function()
        local root = fresh_repo()
        -- diverge: branch off main, commit a change on the branch, then edit further
        git(root, "checkout", "-q", "-b", "feature")
        write(root .. "/a.lua", "local x = 2\nreturn x\n")
        git(root, "commit", "-q", "-am", "feature change")
        write(root .. "/a.lua", "local x = 3\nreturn x\n") -- uncommitted on top
        vim.cmd.edit(root .. "/a.lua")

        -- main... => merge-base(main, HEAD) [the init commit, V1] vs worktree [V3]
        local v = git_src.open({ "main..." })
        assert.is_not_nil(v)
        assert.are.equal(V1, v.model.old_text)
        assert.are.equal("local x = 3\nreturn x\n", v.model.new_text)
        assert.are.equal("main...", v.model.old_rev)
        v:close()
    end)
end)
