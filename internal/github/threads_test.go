package github

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

func TestResolveThread(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		if !strings.Contains(body, "resolveReviewThread") || strings.Contains(body, "unresolveReviewThread") {
			t.Errorf("resolve=true must hit resolveReviewThread: %s", body)
		}
		if !strings.Contains(body, `"threadId":"PRT_1"`) {
			t.Errorf("thread id not threaded: %s", body)
		}
		return resp(200, `{"data":{"result":{"thread":{"isResolved":true}}}}`, nil), nil
	})
	rt, err := c.ResolveThread(context.Background(), "PRT_1", true)
	if err != nil {
		t.Fatal(err)
	}
	if !rt.Resolved {
		t.Errorf("want resolved, got %+v", rt)
	}
}

func TestUnresolveThread(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if !strings.Contains(string(readBody(t, r)), "unresolveReviewThread") {
			t.Error("resolve=false must hit unresolveReviewThread")
		}
		return resp(200, `{"data":{"result":{"thread":{"isResolved":false}}}}`, nil), nil
	})
	rt, err := c.ResolveThread(context.Background(), "PRT_1", false)
	if err != nil {
		t.Fatal(err)
	}
	if rt.Resolved {
		t.Errorf("want unresolved, got %+v", rt)
	}
}

func TestResolveThreadMapsGraphQLError(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, `{"data":null,"errors":[{"type":"NOT_FOUND","message":"no such thread"}]}`, nil), nil
	})
	_, err := c.ResolveThread(context.Background(), "PRT_x", true)
	if codeOf(t, err) != protocol.CodeNotFound {
		t.Fatalf("want not_found, got %v", err)
	}
}
