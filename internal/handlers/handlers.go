// Package handlers implements the protocol methods. each handler decodes its own
// params and returns (result, error); a *protocol.Error carries a closed-set
// code, anything else becomes internal in dispatch.
package handlers

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

// Handler runs one method: decode params, do the work, return a result struct
// (marshalled into Response.Result) or an error.
type Handler func(ctx context.Context, params json.RawMessage) (any, error)

// Registry maps method names to handlers.
type Registry map[string]Handler

// API is the github surface the handlers depend on, declared here (consumer-side)
// so handler logic is mockable independently of the transport. *github.Client
// satisfies it. grown per slice as methods land.
type API interface{}

// Deps are the handler dependencies, injected once at construction (no globals).
type Deps struct {
	GH  API
	Log *slog.Logger
}

// NewRegistry wires every method to its handler.
func NewRegistry(d Deps) Registry {
	return Registry{
		"hello": d.hello,
	}
}

// decode unmarshals params into v, mapping malformed input to bad_request.
func decode(params json.RawMessage, v any) error {
	if len(params) == 0 {
		return nil
	}
	if err := json.Unmarshal(params, v); err != nil {
		return protocol.NewError(protocol.CodeBadRequest, "invalid params: "+err.Error())
	}
	return nil
}
