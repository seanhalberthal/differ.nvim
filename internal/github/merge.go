package github

import (
	"context"

	"github.com/undont/differ.nvim/internal/protocol"
)

// MergePR merges the PR with the given method (MERGE / SQUASH / REBASE). it pre-flights
// mergeability and returns conflict rather than firing a doomed merge; when
// deleteBranch is set the head branch is deleted after a successful merge, best-effort
// (a delete failure does not fail the merge, which is already done). subject/body set
// the merge commit message.
func (c *Client) MergePR(ctx context.Context, owner, repo string, number int, method string, deleteBranch bool, subject, body string) (*Merge, error) {
	var look mergeLookupGQL
	vars := map[string]any{"owner": owner, "repo": repo, "number": number}
	if err := c.graphql(ctx, mergeLookupQuery, vars, &look); err != nil {
		return nil, err
	}
	pr := look.Repository.PullRequest
	if pr.ID == "" {
		return nil, protocol.NewError(protocol.CodeNotFound, "pull request not found")
	}
	if pr.Merged {
		return &Merge{Merged: true}, nil
	}
	if err := mergeBlocked(pr.Mergeable, pr.MergeStateStatus); err != nil {
		return nil, err
	}

	mvars := map[string]any{"prId": pr.ID, "method": method}
	if subject != "" {
		mvars["headline"] = subject
	}
	if body != "" {
		mvars["body"] = body
	}
	var out mergePRGQL
	if err := c.graphql(ctx, mergePRMutation, mvars, &out); err != nil {
		return nil, err
	}
	res := &Merge{
		Merged: out.MergePullRequest.PullRequest.Merged,
		SHA:    out.MergePullRequest.PullRequest.MergeCommit.Oid,
	}

	if deleteBranch && res.Merged && pr.HeadRef.ID != "" {
		// best-effort: the merge is done, so a ref-delete failure is swallowed.
		_ = c.graphql(ctx, deleteRefMutation, map[string]any{"refId": pr.HeadRef.ID}, nil)
	}
	return res, nil
}

// mergeBlocked maps a non-mergeable state to a conflict with a human-readable reason,
// pre-empting GitHub's opaque rejection. CLEAN / UNSTABLE / HAS_HOOKS / UNKNOWN are
// left to proceed (UNKNOWN is transient; GitHub decides on the live mutation).
func mergeBlocked(mergeable, status string) error {
	if mergeable == "CONFLICTING" {
		return protocol.NewError(protocol.CodeConflict, "pull request has merge conflicts")
	}
	switch status {
	case "DIRTY":
		return protocol.NewError(protocol.CodeConflict, "pull request has merge conflicts")
	case "BLOCKED":
		return protocol.NewError(protocol.CodeConflict, "merge is blocked by required reviews or checks")
	case "BEHIND":
		return protocol.NewError(protocol.CodeConflict, "head branch is behind the base; update it before merging")
	case "DRAFT":
		return protocol.NewError(protocol.CodeConflict, "pull request is still a draft")
	}
	return nil
}
