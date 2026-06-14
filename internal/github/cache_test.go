package github

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// blobs are immutable per sha, so a second get_file_versions serves the file bytes
// from cache; only the (uncached) ref lookup re-hits the network.
func TestBlobCacheServesContents(t *testing.T) {
	var refCalls, contentCalls int
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.Contains(r.URL.Path, "/contents/"):
			contentCalls++
			return resp(200, "file body", nil), nil
		case strings.HasSuffix(r.URL.Path, "/pulls/3"):
			refCalls++
			return resp(200, `{"base":{"sha":"BASE"},"head":{"sha":"HEAD"}}`, nil), nil
		}
		t.Fatalf("unexpected path %s", r.URL.Path)
		return nil, nil
	})
	for i := 0; i < 2; i++ {
		if _, err := c.GetFileVersions(context.Background(), "o", "r", 3, "a.go"); err != nil {
			t.Fatal(err)
		}
	}
	if contentCalls != 2 {
		t.Errorf("want 2 content fetches (base+head, once), got %d", contentCalls)
	}
	if refCalls != 2 {
		t.Errorf("refs are not cached, want 2 lookups, got %d", refCalls)
	}
}

func TestThreadCacheAndInvalidation(t *testing.T) {
	threadCalls := 0
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		switch {
		case strings.Contains(body, "GetThreads"):
			threadCalls++
			return resp(200, `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":""}}}}}}`, nil), nil
		case strings.Contains(body, "resolveReviewThread"):
			return resp(200, `{"data":{"result":{"thread":{"isResolved":true}}}}`, nil), nil
		}
		t.Fatalf("unexpected op: %s", body)
		return nil, nil
	})
	ctx := context.Background()
	for i := 0; i < 2; i++ {
		if _, err := c.GetThreads(ctx, "o", "r", 3); err != nil {
			t.Fatal(err)
		}
	}
	if threadCalls != 1 {
		t.Fatalf("second get_threads should be cached, got %d fetches", threadCalls)
	}
	if _, err := c.ResolveThread(ctx, "PRT_1", true); err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetThreads(ctx, "o", "r", 3); err != nil {
		t.Fatal(err)
	}
	if threadCalls != 2 {
		t.Errorf("resolve must invalidate the thread cache, got %d fetches", threadCalls)
	}
}

func TestClearCacheFlushesBlobs(t *testing.T) {
	contentCalls := 0
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if strings.Contains(r.URL.Path, "/contents/") {
			contentCalls++
			return resp(200, "body", nil), nil
		}
		return resp(200, `{"base":{"sha":"BASE"},"head":{"sha":"HEAD"}}`, nil), nil
	})
	ctx := context.Background()
	if _, err := c.GetFileVersions(ctx, "o", "r", 3, "a.go"); err != nil {
		t.Fatal(err)
	}
	c.ClearCache()
	if _, err := c.GetFileVersions(ctx, "o", "r", 3, "a.go"); err != nil {
		t.Fatal(err)
	}
	if contentCalls != 4 {
		t.Errorf("clear should force a refetch: want 4 content calls, got %d", contentCalls)
	}
}
