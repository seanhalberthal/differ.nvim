package github

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

func TestSetFileViewedMarks(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		switch {
		case strings.Contains(body, "PRNodeID"):
			ops = append(ops, "lookup")
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE"}}}}`, nil), nil
		case strings.Contains(body, "markFileAsViewed"):
			ops = append(ops, "mark")
			if !strings.Contains(body, `"prId":"PR_NODE"`) || !strings.Contains(body, `"path":"a.go"`) {
				t.Errorf("mark vars not threaded: %s", body)
			}
			return resp(200, `{"data":{"markFileAsViewed":{"clientMutationId":null}}}`, nil), nil
		}
		t.Fatalf("unexpected request: %s", body)
		return nil, nil
	})
	res, err := c.SetFileViewed(context.Background(), "o", "r", 3, "a.go", true)
	if err != nil {
		t.Fatal(err)
	}
	if res.ViewedState != "VIEWED" {
		t.Errorf("viewed state = %q, want VIEWED", res.ViewedState)
	}
	if len(ops) != 2 || ops[0] != "lookup" || ops[1] != "mark" {
		t.Errorf("want lookup then mark, got %v", ops)
	}
}

func TestSetFileViewedUnmarks(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		if strings.Contains(body, "PRNodeID") {
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE"}}}}`, nil), nil
		}
		if !strings.Contains(body, "unmarkFileAsViewed") {
			t.Errorf("viewed=false must unmark: %s", body)
		}
		return resp(200, `{"data":{"unmarkFileAsViewed":{"clientMutationId":null}}}`, nil), nil
	})
	res, err := c.SetFileViewed(context.Background(), "o", "r", 3, "a.go", false)
	if err != nil {
		t.Fatal(err)
	}
	if res.ViewedState != "UNVIEWED" {
		t.Errorf("viewed state = %q, want UNVIEWED", res.ViewedState)
	}
}
