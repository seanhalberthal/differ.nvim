-- runs under headless nvim: the lualine `filetype` component resolves the source
-- filetype on differ buffers and the native filetype elsewhere. nvim-web-devicons
-- isn't on the test rtp, so the devicon fragment is empty and the output is the
-- bare filetype name, which is what these assertions key off
local lualine = require("differ.lualine")

local function in_buf(setup, fn)
    local buf = vim.api.nvim_create_buf(false, true)
    local prev = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(buf)
    setup(buf)
    local ok, res = pcall(fn)
    vim.api.nvim_set_current_buf(prev)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(ok, res)
    return res
end

describe("lualine filetype component", function()
    it("shows the stashed source filetype on a differ buffer", function()
        local out = in_buf(function(buf)
            vim.bo[buf].filetype = "differdiff"
            vim.b[buf].differ_filetype = "lua"
        end, lualine.filetype)
        assert.are.equal("lua", out)
    end)

    it("falls back to the native filetype off a differ buffer", function()
        local out = in_buf(function(buf)
            vim.bo[buf].filetype = "python"
        end, lualine.filetype)
        assert.are.equal("python", out)
    end)

    it("ignores an empty stash and uses the native filetype", function()
        local out = in_buf(function(buf)
            vim.bo[buf].filetype = "differpanel"
            vim.b[buf].differ_filetype = ""
        end, lualine.filetype)
        assert.are.equal("differpanel", out)
    end)

    it("returns empty when there is no filetype at all", function()
        local out = in_buf(function() end, lualine.filetype)
        assert.are.equal("", out)
    end)
end)
