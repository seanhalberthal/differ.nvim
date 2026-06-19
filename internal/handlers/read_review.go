package handlers

import (
	"context"
	"encoding/json"
)

// getThreads returns the PR's review threads with their comments.
func (d Deps) getThreads(ctx context.Context, params json.RawMessage) (any, error) {
	var p prParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	return d.GH.GetThreads(ctx, p.Owner, p.Repo, p.Number)
}

// getPendingReview returns the viewer's draft review, driving resume.
func (d Deps) getPendingReview(ctx context.Context, params json.RawMessage) (any, error) {
	var p prParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	return d.GH.GetPendingReview(ctx, p.Owner, p.Repo, p.Number)
}

// getTimeline returns the PR's conversation comments + submitted review verdicts.
func (d Deps) getTimeline(ctx context.Context, params json.RawMessage) (any, error) {
	var p prParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	return d.GH.GetTimeline(ctx, p.Owner, p.Repo, p.Number)
}

// getChecks returns the status-check rollup for the PR.
func (d Deps) getChecks(ctx context.Context, params json.RawMessage) (any, error) {
	var p prParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	return d.GH.GetChecks(ctx, p.Owner, p.Repo, p.Number)
}
