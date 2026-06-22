package github

import (
	"context"

	"github.com/undont/differ.nvim/internal/protocol"
)

// SetPRState transitions a PR's lifecycle: ready (mark ready for review), draft
// (convert to draft), closed (close), or open (reopen). it is keyed by the PR node
// id (resolved here) and returns the PR's normalised condition afterwards.
func (c *Client) SetPRState(ctx context.Context, owner, repo string, number int, state string) (*SetPRState, error) {
	mutation, ok := prStateMutation(state)
	if !ok {
		return nil, protocol.NewError(protocol.CodeBadRequest, "state must be ready, draft, closed, or open")
	}
	prID, err := c.prNodeID(ctx, owner, repo, number)
	if err != nil {
		return nil, err
	}
	var out setPRStateGQL
	if err := c.graphql(ctx, mutation, map[string]any{"prId": prID}, &out); err != nil {
		return nil, err
	}
	pr := out.Result.PullRequest
	return &SetPRState{State: normalisePRState(pr.State, pr.IsDraft)}, nil
}

func prStateMutation(state string) (string, bool) {
	switch state {
	case "ready":
		return readyForReviewMutation, true
	case "draft":
		return convertToDraftMutation, true
	case "closed":
		return closePRMutation, true
	case "open":
		return reopenPRMutation, true
	default:
		return "", false
	}
}

// normalisePRState collapses GitHub's (state, isDraft) pair into one condition: an
// open PR reads as draft when isDraft, otherwise open; closed/merged pass through.
func normalisePRState(state string, isDraft bool) string {
	switch state {
	case "CLOSED":
		return "closed"
	case "MERGED":
		return "merged"
	}
	if isDraft {
		return "draft"
	}
	return "open"
}
