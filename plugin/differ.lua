-- command registration; loaded once on startup

if vim.g.loaded_differ then
    return
end
vim.g.loaded_differ = true

require("differ.command").register("Differ", "differ diff viewer")
