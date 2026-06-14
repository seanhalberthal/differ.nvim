package handlers

import (
	"context"
	"encoding/json"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

type setFileViewedParams struct {
	prParams
	Path   string `json:"path"`
	Viewed bool   `json:"viewed"`
}

// setFileViewed syncs a file's per-viewer viewed flag to GitHub (§7.3).
func (d Deps) setFileViewed(ctx context.Context, params json.RawMessage) (any, error) {
	var p setFileViewedParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	if p.Path == "" {
		return nil, protocol.NewError(protocol.CodeBadRequest, "path is required")
	}
	return d.GH.SetFileViewed(ctx, p.Owner, p.Repo, p.Number, p.Path, p.Viewed)
}
