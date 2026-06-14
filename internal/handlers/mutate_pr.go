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

type mergePRParams struct {
	prParams
	Method       string `json:"method"`
	DeleteBranch bool   `json:"delete_branch"`
	Subject      string `json:"subject"`
	Body         string `json:"body"`
}

// mergePR merges the PR with the requested method (§7.3); the github layer pre-checks
// mergeability and returns conflict if it can't merge cleanly.
func (d Deps) mergePR(ctx context.Context, params json.RawMessage) (any, error) {
	var p mergePRParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	method, ok := mergeMethod(p.Method)
	if !ok {
		return nil, protocol.NewError(protocol.CodeBadRequest, "method must be squash, merge, or rebase")
	}
	return d.GH.MergePR(ctx, p.Owner, p.Repo, p.Number, method, p.DeleteBranch, p.Subject, p.Body)
}

// mergeMethod maps the protocol's lowercase method to the GraphQL enum value.
func mergeMethod(m string) (string, bool) {
	switch m {
	case "squash":
		return "SQUASH", true
	case "merge":
		return "MERGE", true
	case "rebase":
		return "REBASE", true
	default:
		return "", false
	}
}
