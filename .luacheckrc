---@diagnostic disable: lowercase-global
---std = "luajit"
unused_args = false
globals = { "vim" }
read_globals = { "describe", "it", "before_each", "after_each", "assert" }
exclude_files = { "cmd", "internal" }
