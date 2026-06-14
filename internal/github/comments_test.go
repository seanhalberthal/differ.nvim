package github

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// commentOp routes the post_comment graphql ops. AddThreadReply must be checked
// before AddThread (the former contains the latter as a substring).
func commentOp(t *testing.T, body []byte) string {
	t.Helper()
	s := string(body)
	for _, op := range []string{"PRNodeID", "AddThreadReply", "AddThread"} {
		if strings.Contains(s, op) {
			return op
		}
	}
	t.Fatalf("unrecognised graphql op: %s", s)
	return ""
}

func TestPostCommentDraftThread(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		if op := commentOp(t, body); op != "AddThread" {
			t.Fatalf("a draft post must not look up the PR node, got op %s", op)
		}
		if !strings.Contains(string(body), `"reviewId":"PRR_1"`) {
			t.Errorf("review id not threaded: %s", body)
		}
		return resp(200, `{"data":{"addPullRequestReviewThread":{"thread":{"id":"PRT_9","comments":{"nodes":[{"fullDatabaseId":"7001"}]}}}}}`, nil), nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 10, Body: "nit", ReviewID: "PRR_1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if pc.ID != 7001 || pc.ThreadID != "PRT_9" {
		t.Errorf("bad result: %+v", pc)
	}
}

func TestPostCommentImmediateThreadLooksUpPRNode(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		op := commentOp(t, body)
		ops = append(ops, op)
		switch op {
		case "PRNodeID":
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE"}}}}`, nil), nil
		case "AddThread":
			if !strings.Contains(string(body), `"prId":"PR_NODE"`) {
				t.Errorf("an immediate post must anchor to the PR node: %s", body)
			}
			return resp(200, `{"data":{"addPullRequestReviewThread":{"thread":{"id":"PRT_1","comments":{"nodes":[{"fullDatabaseId":"42"}]}}}}}`, nil), nil
		}
		t.Fatalf("unexpected op %s", op)
		return nil, nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 5, Body: "hi",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(ops) != 2 || ops[0] != "PRNodeID" || ops[1] != "AddThread" {
		t.Errorf("want lookup then add, got %v", ops)
	}
	if pc.ID != 42 || pc.ThreadID != "PRT_1" {
		t.Errorf("bad result: %+v", pc)
	}
}

// a range comment threads startLine and defaults startSide to side when unset.
func TestPostCommentRangeDefaultsStartSide(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		if !strings.Contains(body, `"startLine":4`) || !strings.Contains(body, `"startSide":"RIGHT"`) {
			t.Errorf("range start fields not threaded: %s", body)
		}
		return resp(200, `{"data":{"addPullRequestReviewThread":{"thread":{"id":"T","comments":{"nodes":[{"fullDatabaseId":"1"}]}}}}}`, nil), nil
	})
	_, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 8, StartLine: 4, Body: "range", ReviewID: "PRR_1",
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestPostCommentReply(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		if op := commentOp(t, body); op != "AddThreadReply" {
			t.Fatalf("a reply must use the reply mutation, got op %s", op)
		}
		if !strings.Contains(string(body), `"threadId":"PRT_5"`) {
			t.Errorf("thread id not threaded: %s", body)
		}
		return resp(200, `{"data":{"addPullRequestReviewThreadReply":{"comment":{"fullDatabaseId":"9099"}}}}`, nil), nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Body: "thanks", InReplyTo: "PRT_5",
	})
	if err != nil {
		t.Fatal(err)
	}
	if pc.ID != 9099 || pc.ThreadID != "PRT_5" {
		t.Errorf("reply result: %+v", pc)
	}
}
