package github

import (
	"context"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

// StartReview creates a pending review on the PR, or returns the viewer's existing
// one. it is idempotent (§7.5): GitHub allows one pending review per viewer per PR,
// so resume reattaches to the live draft instead of orphaning a second one.
func (c *Client) StartReview(ctx context.Context, owner, repo string, number int) (*StartReview, error) {
	var look startReviewLookupGQL
	vars := map[string]any{"owner": owner, "repo": repo, "number": number}
	if err := c.graphql(ctx, startReviewLookupQuery, vars, &look); err != nil {
		return nil, err
	}
	if nodes := look.Repository.PullRequest.Reviews.Nodes; len(nodes) > 0 {
		return &StartReview{ReviewID: nodes[0].ID}, nil
	}
	prID := look.Repository.PullRequest.ID
	if prID == "" {
		return nil, protocol.NewError(protocol.CodeNotFound, "pull request not found")
	}

	var created addReviewGQL
	if err := c.graphql(ctx, addReviewMutation, map[string]any{"prId": prID}, &created); err != nil {
		return nil, err
	}
	return &StartReview{ReviewID: created.AddPullRequestReview.PullRequestReview.ID}, nil
}

// SubmitReview finalizes a pending review with the given event, returning the
// submitted review's numeric id. the review id is a global node id, so the PR
// coordinates aren't needed here.
func (c *Client) SubmitReview(ctx context.Context, reviewID, event, body string) (*SubmitReview, error) {
	var out submitReviewGQL
	vars := map[string]any{"reviewId": reviewID, "event": event, "body": body}
	if err := c.graphql(ctx, submitReviewMutation, vars, &out); err != nil {
		return nil, err
	}
	c.cache.invalidateThreads()
	return &SubmitReview{ID: parseID(out.SubmitPullRequestReview.PullRequestReview.FullDatabaseID)}, nil
}

// DiscardReview deletes a pending review and its unsubmitted comments.
func (c *Client) DiscardReview(ctx context.Context, reviewID string) error {
	if err := c.graphql(ctx, deleteReviewMutation, map[string]any{"reviewId": reviewID}, nil); err != nil {
		return err
	}
	c.cache.invalidateThreads()
	return nil
}
