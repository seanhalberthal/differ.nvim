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

GO_PKG  := ./cmd/dipher-sidecar
GO_BIN  := bin/dipher-sidecar

.PHONY: help test test-nvim test-all lint fmt fmt-check go-build go-test go-vet check clean

# ──────────────────────────────────────────────────────────────────────────────
##@ Lua
# ──────────────────────────────────────────────────────────────────────────────

test: ## Run pure-Lua unit tests (no Neovim runtime)
	@$(INFO) "Running unit tests"
	@busted --run unit

test-nvim: ## Run headless-nvim tests (needs nlua on PATH)
	@$(INFO) "Running headless-nvim tests"
	@eval $$(luarocks --lua-version=5.1 path) && busted --lua=nlua test/nvim

test-all: test test-nvim ## Run both unit and headless-nvim suites

lint: ## Luacheck + stylua --check on Lua sources
	@$(INFO) "Linting"
	@luacheck lua
	@stylua --check lua plugin test
	@$(OK) "Lint clean"

fmt: ## Format Lua sources with stylua
	@stylua lua plugin test
	@$(OK) "Formatted"

fmt-check: ## Verify Lua formatting without writing
	@stylua --check lua plugin test

# ──────────────────────────────────────────────────────────────────────────────
##@ Go sidecar
# ──────────────────────────────────────────────────────────────────────────────

go-build: ## Build the dipher-sidecar binary into bin/
	@$(INFO) "Building $(GO_BIN)"
	@go build -o $(GO_BIN) $(GO_PKG)
	@$(OK) "Built $(GO_BIN)"

go-test: ## Run Go tests
	@go test ./...

go-vet: ## Run go vet over the module
	@go vet ./...

# ──────────────────────────────────────────────────────────────────────────────
##@ Aggregate
# ──────────────────────────────────────────────────────────────────────────────

check: lint test test-nvim go-vet go-test ## Run the full quality gate

clean: ## Remove build artefacts
	@rm -rf bin dipher-sidecar
	@$(OK) "Cleaned"

# ──────────────────────────────────────────────────────────────────────────────
##@ Meta
# ──────────────────────────────────────────────────────────────────────────────

help: ## Show this help message
	@cols=$$( { stty size </dev/tty; } 2>/dev/null | cut -d' ' -f2 ); \
	[ -n "$$cols" ] || cols=$$(tput cols 2>/dev/null); \
	case "$$cols" in ''|*[!0-9]*) cols=100;; esac; \
	[ "$$cols" -ge 40 ] || cols=100; \
	printf "\n  $(BOLD)dipher.nvim$(NC) — make targets\n\n"; \
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
