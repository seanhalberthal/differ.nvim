// Package logx provides the sidecar's structured logger. it writes to stderr
// ONLY; stdout is reserved for the protocol stream. tokens must never be
// passed to it.
package logx

import (
	"log/slog"
	"os"
)

// New returns a slog logger writing text to stderr at the given level.
func New(level slog.Level) *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
}
