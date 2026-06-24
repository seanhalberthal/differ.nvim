// fake-sidecar is a demo-only stand-in for cmd/differ-sidecar: it speaks the same
// newline-delimited JSON protocol over stdio but serves canned, in-memory PR data
// instead of calling github, so the vhs recording drives the real PR frontend with
// no network, no gh, and no token. it reuses the real server + handler registry and
// only swaps the github API for a fixture, so the wire contract can't drift.
//
// it lives under .demo/ (a dot-dir the go tool excludes from ./... wildcards, so it
// never lands in go test/vet/lint) yet stays in the main module so it can import the
// internal packages. build it explicitly:
//
//	go build -o .demo/fake-sidecar/fake-sidecar ./.demo/fake-sidecar
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/undont/differ.nvim/internal/handlers"
	"github.com/undont/differ.nvim/internal/logx"
	"github.com/undont/differ.nvim/internal/server"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	log := logx.New(slog.LevelInfo)

	reg := handlers.NewRegistry(handlers.Deps{GH: newFixture(), Log: log})
	srv := server.New(reg, log)

	if err := srv.Run(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "fake-sidecar:", err)
		os.Exit(1)
	}
}
