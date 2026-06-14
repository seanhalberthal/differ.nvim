package github

import (
	"context"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

// PostComment creates a review comment. InReplyTo (a thread node id) replies into
// an existing thread; otherwise a new thread is opened, joining the pending draft
// when ReviewID is set or posting immediately when it isn't. anchor shape (side,
// line ordering) is validated by the handler before this runs (§7.5).
func (c *Client) PostComment(ctx context.Context, owner, repo string, number int, in PostCommentInput) (*PostComment, error) {
	var (
		res *PostComment
		err error
	)
	if in.InReplyTo != "" {
		res, err = c.replyToThread(ctx, in)
	} else {
		res, err = c.openThread(ctx, owner, repo, number, in)
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

func (c *Client) openThread(ctx context.Context, owner, repo string, number int, in PostCommentInput) (*PostComment, error) {
	vars := map[string]any{"path": in.Path, "body": in.Body, "line": in.Line, "side": in.Side}
	if in.StartLine != 0 {
		side := in.StartSide
		if side == "" {
			side = in.Side
		}
		vars["startLine"] = in.StartLine
		vars["startSide"] = side
	}
	if in.ReviewID != "" {
		vars["reviewId"] = in.ReviewID
	} else {
		prID, err := c.prNodeID(ctx, owner, repo, number)
		if err != nil {
			return nil, err
		}
		vars["prId"] = prID
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
