package handlers

import (
	"context"
	"encoding/json"

	"github.com/undont/differ.nvim/internal/protocol"
)

type listPRsParams struct {
	Owner  string `json:"owner"`
	Repo   string `json:"repo"`
	Filter string `json:"filter"`
}

// listPRs returns the PR picker list.
func (d Deps) listPRs(ctx context.Context, params json.RawMessage) (any, error) {
	var p listPRsParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requireRepo(p.Owner, p.Repo); err != nil {
		return nil, err
	}
	return d.GH.ListPRs(ctx, p.Owner, p.Repo, p.Filter)
}

// prParams is the {owner, repo, number} shorthand shared by the PR-scoped methods.
type prParams struct {
	Owner  string `json:"owner"`
	Repo   string `json:"repo"`
	Number int    `json:"number"`
}

// getPR returns full PR detail incl. per-file viewed state and rename info.
func (d Deps) getPR(ctx context.Context, params json.RawMessage) (any, error) {
	var p prParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	return d.GH.GetPR(ctx, p.Owner, p.Repo, p.Number)
}

func requireRepo(owner, repo string) error {
	if owner == "" || repo == "" {
		return protocol.NewError(protocol.CodeBadRequest, "owner and repo are required")
	}
	return nil
}

func requirePR(owner, repo string, number int) error {
	if err := requireRepo(owner, repo); err != nil {
		return err
	}
	if number <= 0 {
		return protocol.NewError(protocol.CodeBadRequest, "number is required")
	}
	return nil
}
