package handlers

import (
	"context"
	"encoding/json"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

type resolveThreadParams struct {
	prParams
	ThreadID string `json:"thread_id"`
	Resolved bool   `json:"resolved"`
}

// resolveThread toggles a review thread's resolved state (§7.3). the thread node id
// is global, but pr is validated for protocol consistency (and keys the thread-cache
// invalidation, §7.5).
func (d Deps) resolveThread(ctx context.Context, params json.RawMessage) (any, error) {
	var p resolveThreadParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	if p.ThreadID == "" {
		return nil, protocol.NewError(protocol.CodeBadRequest, "thread_id is required")
	}
	return d.GH.ResolveThread(ctx, p.ThreadID, p.Resolved)
}
