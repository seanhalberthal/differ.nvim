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

// an immediate (no-review) post publishes via REST: resolve the head sha, then POST
// the comment to /pulls/{n}/comments. it must NOT take the GraphQL draft path (which
// would attach to the viewer's pending review and stay unpublished).
func TestPostCommentImmediatePublishesViaREST(t *testing.T) {
	var calls []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		calls = append(calls, r.Method+" "+r.URL.Path)
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/repos/o/r/pulls/3":
			return resp(200, `{"base":{"sha":"base1"},"head":{"sha":"head9"}}`, nil), nil
		case r.Method == http.MethodPost && r.URL.Path == "/repos/o/r/pulls/3/comments":
			body := string(readBody(t, r))
			for _, want := range []string{`"commit_id":"head9"`, `"path":"a.go"`, `"line":5`, `"side":"RIGHT"`, `"body":"hi"`} {
				if !strings.Contains(body, want) {
					t.Errorf("immediate REST payload missing %s: %s", want, body)
				}
			}
			return resp(201, `{"id":42}`, nil), nil
		}
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		return nil, nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 5, Body: "hi",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || calls[0] != "GET /repos/o/r/pulls/3" || calls[1] != "POST /repos/o/r/pulls/3/comments" {
		t.Errorf("want head lookup then REST post, got %v", calls)
	}
	if pc.ID != 42 || pc.ThreadID != "" {
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
