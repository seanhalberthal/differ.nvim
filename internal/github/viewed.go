package github

import "context"

// SetFileViewed toggles a file's per-viewer viewed flag, returning the resulting
// state. the mutation is keyed by the PR node id (resolved here) and the path; the
// outcome is deterministic, so it isn't read back from the payload.
func (c *Client) SetFileViewed(ctx context.Context, owner, repo string, number int, path string, viewed bool) (*SetFileViewed, error) {
	prID, err := c.prNodeID(ctx, owner, repo, number)
	if err != nil {
		return nil, err
	}
	mutation, state := unmarkFileViewedMutation, "UNVIEWED"
	if viewed {
		mutation, state = markFileViewedMutation, "VIEWED"
	}
	if err := c.graphql(ctx, mutation, map[string]any{"prId": prID, "path": path}, nil); err != nil {
		return nil, err
	}
	return &SetFileViewed{ViewedState: state}, nil
}
