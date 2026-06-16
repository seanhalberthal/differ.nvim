package github

import (
	"context"
	"strconv"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

// PostComment creates a review comment. InReplyTo (a thread node id) replies into an
// existing thread; with ReviewID set a new thread joins the pending draft (GraphQL);
// otherwise the comment publishes immediately (REST). anchor shape (side, line
// ordering) is validated by the handler before this runs (§7.5).
func (c *Client) PostComment(ctx context.Context, owner, repo string, number int, in PostCommentInput) (*PostComment, error) {
	var (
		res *PostComment
		err error
	)
	switch {
	case in.InReplyTo != "":
		res, err = c.replyToThread(ctx, in)
	case in.ReviewID != "":
		res, err = c.draftThread(ctx, in)
	default:
		res, err = c.publishComment(ctx, owner, repo, number, in)
	}
	if err == nil {
		c.cache.invalidateThreads()
	}
	return res, err
}

func (c *Client) replyToThread(ctx context.Context, in PostCommentInput) (*PostComment, error) {
	vars := map[string]any{"threadId": in.InReplyTo, "body": in.Body}
	if in.ReviewID != "" {
		vars["reviewId"] = in.ReviewID
	}
	var out addReplyGQL
	if err := c.graphql(ctx, addThreadReplyMutation, vars, &out); err != nil {
		return nil, err
	}
	return &PostComment{
		ID:       parseID(out.AddPullRequestReviewThreadReply.Comment.FullDatabaseID),
		ThreadID: in.InReplyTo,
	}, nil
}

// draftThread opens a new thread inside the viewer's pending review (a draft). it
// stays unpublished until submit_review, so the caller must hold a ReviewID.
func (c *Client) draftThread(ctx context.Context, in PostCommentInput) (*PostComment, error) {
	vars := map[string]any{
		"path":     in.Path,
		"body":     in.Body,
		"line":     in.Line,
		"side":     in.Side,
		"reviewId": in.ReviewID,
	}
	if in.StartLine != 0 {
		side := in.StartSide
		if side == "" {
			side = in.Side
		}
		vars["startLine"] = in.StartLine
		vars["startSide"] = side
	}

	var out addThreadGQL
	if err := c.graphql(ctx, addThreadMutation, vars, &out); err != nil {
		return nil, err
	}
	thread := out.AddPullRequestReviewThread.Thread
	pc := &PostComment{ThreadID: thread.ID}
	if len(thread.Comments.Nodes) > 0 {
		pc.ID = parseID(thread.Comments.Nodes[0].FullDatabaseID)
	}
	return pc, nil
}

// publishComment posts a published (non-draft) review comment via REST. unlike the
// GraphQL addPullRequestReviewThread path (which always drafts into a pending review,
// and would attach to the viewer's existing draft), the REST endpoint publishes
// immediately and never touches any pending review. it anchors to the current head.
func (c *Client) publishComment(ctx context.Context, owner, repo string, number int, in PostCommentInput) (*PostComment, error) {
	_, head, err := c.prRefs(ctx, owner, repo, number)
	if err != nil {
		return nil, err
	}
	payload := map[string]any{
		"body":      in.Body,
		"commit_id": head,
		"path":      in.Path,
		"line":      in.Line,
		"side":      in.Side,
	}
	if in.StartLine != 0 {
		side := in.StartSide
		if side == "" {
			side = in.Side
		}
		payload["start_line"] = in.StartLine
		payload["start_side"] = side
	}
	rawURL := c.restURL + "/repos/" + owner + "/" + repo + "/pulls/" + strconv.Itoa(number) + "/comments"
	var out restComment
	if err := c.postJSON(ctx, rawURL, payload, &out); err != nil {
		return nil, err
	}
	// REST returns the comment, not its thread; the frontend re-fetches threads after
	// a post, so the thread node id isn't needed here
	return &PostComment{ID: out.ID, ThreadID: ""}, nil
}

// prNodeID resolves a PR's GraphQL node id (the anchor for review state mutations).
func (c *Client) prNodeID(ctx context.Context, owner, repo string, number int) (string, error) {
	var out prNodeIDGQL
	vars := map[string]any{"owner": owner, "repo": repo, "number": number}
	if err := c.graphql(ctx, prNodeIDQuery, vars, &out); err != nil {
		return "", err
	}
	if id := out.Repository.PullRequest.ID; id != "" {
		return id, nil
	}
	return "", protocol.NewError(protocol.CodeNotFound, "pull request not found")
}
