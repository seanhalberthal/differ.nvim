// differ-sidecar speaks newline-delimited JSON over stdio to the Lua client.
// it owns all GitHub API interaction for the PR-review frontend.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/seanhalberthal/differ.nvim/internal/github"
	"github.com/seanhalberthal/differ.nvim/internal/handlers"
	"github.com/seanhalberthal/differ.nvim/internal/logx"
	"github.com/seanhalberthal/differ.nvim/internal/server"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	log := logx.New(slog.LevelInfo)

	// token resolution failure is non-fatal: the handshake still works and the
	// error is handed to the client so only PR methods surface gh_missing/auth.
	token, tokenErr := github.ResolveToken()
	if tokenErr != nil {
		log.Warn("github auth not ready", "err", tokenErr)
	}
	gh := github.New(nil, token, tokenErr)

	reg := handlers.NewRegistry(handlers.Deps{GH: gh, Log: log})
	srv := server.New(reg, log)

	if err := srv.Run(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "differ-sidecar:", err)
		os.Exit(1)
	}
}
