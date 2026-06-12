-- Command registration; loaded once on startup

if vim.g.loaded_dipher then
    return
end
vim.g.loaded_dipher = true

vim.api.nvim_create_user_command("Dipher", function(opts)
    require("dipher.command").dispatch(opts.fargs)
end, {
    nargs = "*",
    desc = "dipher diff viewer",
    complete = function(arglead, cmdline)
        return require("dipher.command").complete(arglead, cmdline)
    end,
})
