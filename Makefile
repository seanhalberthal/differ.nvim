.PHONY: test test-nvim lint fmt go-build go-test all

# Pure Lua units (no Neovim runtime) via busted
test:
	busted --run unit

# Headless-nvim units (need vim.diff etc); requires nlua on PATH
test-nvim:
	eval $$(luarocks --lua-version=5.1 path) && busted --lua=nlua test/nvim

lint:
	luacheck lua
	stylua --check lua plugin test

fmt:
	stylua lua plugin test

go-build:
	go build ./...

go-test:
	go test ./...

all: lint test test-nvim go-test
