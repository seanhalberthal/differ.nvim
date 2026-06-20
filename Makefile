SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ──────────────────────────────────────────────────────────────────────────────
#  Colours
# ──────────────────────────────────────────────────────────────────────────────
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
CYAN   := \033[0;36m
BOLD   := \033[1m
NC     := \033[0m

INFO := printf "$(CYAN)› %s$(NC)\n"
OK   := printf "$(GREEN)✓$(NC) %s\n"

GO_PKG  := ./cmd/differ-sidecar
GO_BIN  := bin/differ-sidecar
# stamped into protocol.Binary so the hello handshake reports a real version,
# not "dev"; falls back to "dev" outside a git checkout
GO_VERSION := $(shell git describe --tags --always 2>/dev/null | sed 's/^v//' || echo dev)
GO_LDFLAGS := -X github.com/seanhalberthal/differ.nvim/internal/protocol.Binary=$(GO_VERSION)

.PHONY: help \
	lua-test lua-test-unit lua-test-nvim lua-lint lua-fmt lua-fmt-check \
	go-build go-test go-vet go-lint go-fmt go-fmt-check \
	test lint fmt fmt-check check clean

# ──────────────────────────────────────────────────────────────────────────────
##@ Lua
# ──────────────────────────────────────────────────────────────────────────────

lua-test: lua-test-unit lua-test-nvim ## Run both Lua suites (unit + headless-nvim)

lua-test-unit: ## Run pure-Lua unit tests only (fast, no Neovim runtime)
	@$(INFO) "Running unit tests"
	@busted --run unit

lua-test-nvim: ## Run headless-nvim tests (needs nlua on PATH)
	@$(INFO) "Running headless-nvim tests"
	@eval $$(luarocks --lua-version=5.1 path) && busted --lua=nlua --run nvim

lua-lint: ## Luacheck + stylua --check on Lua sources
	@$(INFO) "Linting Lua"
	@luacheck lua
	@stylua --check lua plugin test
	@$(OK) "Lua lint clean"

lua-fmt: ## Format Lua sources with stylua
	@stylua lua plugin test
	@$(OK) "Lua formatted"

lua-fmt-check: ## Verify Lua formatting without writing
	@stylua --check lua plugin test

# ──────────────────────────────────────────────────────────────────────────────
##@ Go sidecar
# ──────────────────────────────────────────────────────────────────────────────

go-build: ## Build the differ-sidecar binary into bin/
	@$(INFO) "Building $(GO_BIN) ($(GO_VERSION))"
	@go build -ldflags "$(GO_LDFLAGS)" -o $(GO_BIN) $(GO_PKG)
	@$(OK) "Built $(GO_BIN)"

go-test: ## Run Go tests
	@go test ./...

go-vet: ## Run go vet over the module
	@go vet ./...

go-lint: ## Run golangci-lint over the module
	@$(INFO) "Linting Go"
	@golangci-lint run ./...
	@$(OK) "Go lint clean"

go-fmt: ## Format Go sources with gofmt
	@gofmt -w cmd internal
	@$(OK) "Go formatted"

go-fmt-check: ## Verify Go formatting without writing
	@out=$$(gofmt -l cmd internal); \
	if [ -n "$$out" ]; then \
		printf "$(RED)gofmt needed:$(NC)\n%s\n" "$$out"; \
		exit 1; \
	fi

# ──────────────────────────────────────────────────────────────────────────────
##@ Aggregate
# ──────────────────────────────────────────────────────────────────────────────

test: lua-test go-test ## Run every test suite (Lua + Go)

lint: lua-lint go-lint ## Lint the whole codebase (Lua + Go)

fmt: lua-fmt go-fmt ## Format the whole codebase (Lua + Go)

fmt-check: lua-fmt-check go-fmt-check ## Verify formatting across the codebase

check: lint go-vet test ## Run the full quality gate

clean: ## Remove build artefacts
	@rm -rf bin differ-sidecar
	@$(OK) "Cleaned"

# ──────────────────────────────────────────────────────────────────────────────
##@ Meta
# ──────────────────────────────────────────────────────────────────────────────

help: ## Show this help message
	@cols=$$( { stty size </dev/tty; } 2>/dev/null | cut -d' ' -f2 ); \
	[ -n "$$cols" ] || cols=$$(tput cols 2>/dev/null); \
	case "$$cols" in ''|*[!0-9]*) cols=100;; esac; \
	[ "$$cols" -ge 40 ] || cols=100; \
	printf "\n  $(BOLD)differ.nvim$(NC) — make targets\n\n"; \
	awk -v width="$$cols" ' \
		function wrap(text, w, ind,    n, words, i, line, out, pad) { \
			pad = sprintf("%" ind "s", ""); \
			n = split(text, words, " "); line = ""; out = ""; \
			for (i = 1; i <= n; i++) { \
				if (line == "") line = words[i]; \
				else if (length(line) + 1 + length(words[i]) <= w - ind) line = line " " words[i]; \
				else { out = out line "\n" pad; line = words[i]; } \
			} \
			return out line; \
		} \
		/^##@ / { order[++cnt] = "S\t" substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*## / { \
			split($$0, a, /:.*## /); \
			order[++cnt] = "T\t" a[1] "\t" a[2]; \
			if (length(a[1]) > maxname) maxname = length(a[1]); \
		} \
		END { \
			ind = maxname + 5; \
			fmt = "  $(GREEN)%-" maxname "s$(NC)  %s\n"; \
			for (i = 1; i <= cnt; i++) { \
				split(order[i], p, "\t"); \
				if (p[1] == "S") printf "\n  $(YELLOW)%s$(NC)\n", p[2]; \
				else printf fmt, p[2], wrap(p[3], width, ind); \
			} \
			printf "\n"; \
		} \
	' $(MAKEFILE_LIST)
