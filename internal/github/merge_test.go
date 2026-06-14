package github

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

func mergeOp(t *testing.T, body []byte) string {
	t.Helper()
	s := string(body)
	for _, op := range []string{"MergeLookup", "Merge", "DeleteRef"} {
		if strings.Contains(s, op) {
			return op
		}
	}
	t.Fatalf("unrecognised graphql op: %s", s)
	return ""
}

func TestMergePRClean(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		op := mergeOp(t, body)
		ops = append(ops, op)
		switch op {
		case "MergeLookup":
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","merged":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRef":{"id":"REF_1"}}}}}`, nil), nil
		case "Merge":
			if !strings.Contains(string(body), `"method":"SQUASH"`) {
				t.Errorf("merge method not threaded: %s", body)
			}
			return resp(200, `{"data":{"mergePullRequest":{"pullRequest":{"merged":true,"mergeCommit":{"oid":"deadbeef"}}}}}`, nil), nil
		}
		t.Fatalf("unexpected op %s", op)
		return nil, nil
	})
	m, err := c.MergePR(context.Background(), "o", "r", 3, "SQUASH", false, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !m.Merged || m.SHA != "deadbeef" {
		t.Errorf("bad result: %+v", m)
	}
	if len(ops) != 2 || ops[0] != "MergeLookup" || ops[1] != "Merge" {
		t.Errorf("want lookup then merge, got %v", ops)
	}
}

func TestMergePRConflictingPreemptsMerge(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if mergeOp(t, readBody(t, r)) != "MergeLookup" {
			t.Fatal("a conflicting PR must not reach the merge mutation")
		}
		return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","merged":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","headRef":{"id":"REF_1"}}}}}`, nil), nil
	})
	_, err := c.MergePR(context.Background(), "o", "r", 3, "MERGE", false, "", "")
	if codeOf(t, err) != protocol.CodeConflict {
		t.Fatalf("want conflict, got %v", err)
	}
}

func TestMergePRBlockedIsConflict(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","merged":false,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","headRef":{"id":"REF_1"}}}}}`, nil), nil
	})
	_, err := c.MergePR(context.Background(), "o", "r", 3, "MERGE", false, "", "")
	if codeOf(t, err) != protocol.CodeConflict {
		t.Fatalf("want conflict for a blocked PR, got %v", err)
	}
}

func TestMergePRAlreadyMerged(t *testing.T) {
	calls := 0
	c := newClient(func(*http.Request) (*http.Response, error) {
		calls++
		return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","merged":true,"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRef":{"id":"REF_1"}}}}}`, nil), nil
	})
	m, err := c.MergePR(context.Background(), "o", "r", 3, "MERGE", false, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !m.Merged {
		t.Errorf("already-merged should report merged, got %+v", m)
	}
	if calls != 1 {
		t.Errorf("already-merged must not fire the merge mutation, calls=%d", calls)
	}
}

func TestMergePRDeletesBranch(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		op := mergeOp(t, body)
		ops = append(ops, op)
		switch op {
		case "MergeLookup":
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","merged":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRef":{"id":"REF_1"}}}}}`, nil), nil
		case "Merge":
			return resp(200, `{"data":{"mergePullRequest":{"pullRequest":{"merged":true,"mergeCommit":{"oid":"sha1"}}}}}`, nil), nil
		case "DeleteRef":
			if !strings.Contains(string(body), `"refId":"REF_1"`) {
				t.Errorf("delete ref id not threaded: %s", body)
			}
			return resp(200, `{"data":{"deleteRef":{"clientMutationId":null}}}`, nil), nil
		}
		t.Fatalf("unexpected op %s", op)
		return nil, nil
	})
	m, err := c.MergePR(context.Background(), "o", "r", 3, "REBASE", true, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !m.Merged {
		t.Errorf("bad result: %+v", m)
	}
	if len(ops) != 3 || ops[2] != "DeleteRef" {
		t.Errorf("want lookup, merge, delete; got %v", ops)
	}
}
