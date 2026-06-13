// dipher-sidecar speaks newline-delimited JSON over stdio to the Lua client.
// it owns all GitHub API interaction for the PR-review frontend (§4, §7).
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/seanhalberthal/dipher.nvim/internal/handlers"
	"github.com/seanhalberthal/dipher.nvim/internal/logx"
	"github.com/seanhalberthal/dipher.nvim/internal/server"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	log := logx.New(slog.LevelInfo)
	reg := handlers.NewRegistry(handlers.Deps{Log: log})
	srv := server.New(reg, log)

	if err := srv.Run(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "dipher-sidecar:", err)
		os.Exit(1)
	}
}
