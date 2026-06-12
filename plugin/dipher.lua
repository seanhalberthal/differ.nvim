-- Command registration; loaded once on startup

if vim.g.loaded_dipher then
    return
end
vim.g.loaded_dipher = true

-- TODO: subcommand router (:Dipher [rev] | pr | layout | context | cache)
vim.api.nvim_create_user_command("Dipher", function(_)
    vim.notify("dipher: not yet implemented", vim.log.levels.INFO)
end, { nargs = "*", desc = "dipher diff viewer" })
