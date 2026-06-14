package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"testing"

	"github.com/seanhalberthal/dipher.nvim/internal/github"
	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

// mockAPI records what it was called with so handler routing/validation can be
// asserted without the github transport.
type mockAPI struct {
	prs         []github.PR
	detail      *github.PRDetail
	gotFilter   string
	gotNumber   int
	gotPath     string
	gotReviewID string
	gotEvent    string
	gotComment  github.PostCommentInput
	gotThreadID string
	gotResolved bool
	gotViewed   bool
	called      bool
}

func (m *mockAPI) ListPRs(_ context.Context, _, _, filter string) ([]github.PR, error) {
	m.called = true
	m.gotFilter = filter
	return m.prs, nil
}

func (m *mockAPI) GetPR(_ context.Context, _, _ string, number int) (*github.PRDetail, error) {
	m.called = true
	m.gotNumber = number
	return m.detail, nil
}

func (m *mockAPI) GetFileVersions(_ context.Context, _, _ string, number int, path string) (*github.FileVersions, error) {
	m.called = true
	m.gotNumber = number
	m.gotPath = path
	return &github.FileVersions{}, nil
}

func (m *mockAPI) GetThreads(_ context.Context, _, _ string, number int) ([]github.Thread, error) {
	m.called = true
	m.gotNumber = number
	return nil, nil
}

func (m *mockAPI) GetPendingReview(_ context.Context, _, _ string, number int) (*github.PendingReview, error) {
	m.called = true
	m.gotNumber = number
	return &github.PendingReview{}, nil
}

func (m *mockAPI) GetChecks(_ context.Context, _, _ string, number int) (*github.Checks, error) {
	m.called = true
	m.gotNumber = number
	return &github.Checks{}, nil
}

func (m *mockAPI) StartReview(_ context.Context, _, _ string, number int) (*github.StartReview, error) {
	m.called = true
	m.gotNumber = number
	return &github.StartReview{ReviewID: "PRR_1"}, nil
}

func (m *mockAPI) SubmitReview(_ context.Context, reviewID, event, _ string) (*github.SubmitReview, error) {
	m.called = true
	m.gotReviewID = reviewID
	m.gotEvent = event
	return &github.SubmitReview{ID: 99}, nil
}

func (m *mockAPI) DiscardReview(_ context.Context, reviewID string) error {
	m.called = true
	m.gotReviewID = reviewID
	return nil
}

func (m *mockAPI) PostComment(_ context.Context, _, _ string, number int, in github.PostCommentInput) (*github.PostComment, error) {
	m.called = true
	m.gotNumber = number
	m.gotComment = in
	return &github.PostComment{ID: 555, ThreadID: "PRT_1"}, nil
}

func (m *mockAPI) ResolveThread(_ context.Context, threadID string, resolved bool) (*github.ResolveThread, error) {
	m.called = true
	m.gotThreadID = threadID
	m.gotResolved = resolved
	return &github.ResolveThread{Resolved: resolved}, nil
}

func (m *mockAPI) SetFileViewed(_ context.Context, _, _ string, number int, path string, viewed bool) (*github.SetFileViewed, error) {
	m.called = true
	m.gotNumber = number
	m.gotPath = path
	m.gotViewed = viewed
	state := "UNVIEWED"
	if viewed {
		state = "VIEWED"
	}
	return &github.SetFileViewed{ViewedState: state}, nil
}

func deps(m *mockAPI) Deps {
	return Deps{GH: m, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func wantBadRequest(t *testing.T, err error) {
	t.Helper()
	var pe *protocol.Error
	if !errors.As(err, &pe) || pe.Code != protocol.CodeBadRequest {
		t.Fatalf("want bad_request, got %v", err)
	}
}

func TestListPRsRoutes(t *testing.T) {
	m := &mockAPI{prs: []github.PR{{Number: 9}}}
	res, err := deps(m).listPRs(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","filter":"mine"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotFilter != "mine" {
		t.Errorf("filter not forwarded: %q", m.gotFilter)
	}
	if prs := res.([]github.PR); len(prs) != 1 || prs[0].Number != 9 {
		t.Errorf("result not forwarded: %+v", res)
	}
}

func TestListPRsRequiresRepo(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).listPRs(context.Background(), json.RawMessage(`{"owner":"o"}`))
	wantBadRequest(t, err)
	if m.called {
		t.Error("GH must not be called when validation fails")
	}
}

func TestGetPRRoutes(t *testing.T) {
	m := &mockAPI{detail: &github.PRDetail{Title: "T"}}
	res, err := deps(m).getPR(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":42}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotNumber != 42 {
		t.Errorf("number not forwarded: %d", m.gotNumber)
	}
	if res.(*github.PRDetail).Title != "T" {
		t.Errorf("result not forwarded: %+v", res)
	}
}

func TestGetPRRequiresNumber(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).getPR(context.Background(), json.RawMessage(`{"owner":"o","repo":"r"}`))
	wantBadRequest(t, err)
	if m.called {
		t.Error("GH must not be called without a number")
	}
}

func TestMalformedParams(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).getPR(context.Background(), json.RawMessage(`{"number":"not-an-int"}`))
	wantBadRequest(t, err)
}

func TestGetFileVersionsRoutes(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).getFileVersions(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":7,"path":"a.go"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotNumber != 7 || m.gotPath != "a.go" {
		t.Errorf("params not forwarded: number=%d path=%q", m.gotNumber, m.gotPath)
	}
}

func TestGetFileVersionsRequiresPath(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).getFileVersions(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":7}`))
	wantBadRequest(t, err)
	if m.called {
		t.Error("GH must not be called without a path")
	}
}

// the PR-scoped read methods share requirePR; one table covers their routing and
// the missing-number guard.
func TestPRScopedReadMethods(t *testing.T) {
	good := json.RawMessage(`{"owner":"o","repo":"r","number":5}`)
	noNum := json.RawMessage(`{"owner":"o","repo":"r"}`)
	cases := []struct {
		name string
		fn   func(Deps) func(context.Context, json.RawMessage) (any, error)
	}{
		{"get_threads", func(d Deps) func(context.Context, json.RawMessage) (any, error) { return d.getThreads }},
		{"get_pending_review", func(d Deps) func(context.Context, json.RawMessage) (any, error) { return d.getPendingReview }},
		{"get_checks", func(d Deps) func(context.Context, json.RawMessage) (any, error) { return d.getChecks }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := &mockAPI{}
			if _, err := tc.fn(deps(m))(context.Background(), good); err != nil {
				t.Fatalf("routing: %v", err)
			}
			if m.gotNumber != 5 {
				t.Errorf("number not forwarded: %d", m.gotNumber)
			}
			m2 := &mockAPI{}
			_, err := tc.fn(deps(m2))(context.Background(), noNum)
			wantBadRequest(t, err)
			if m2.called {
				t.Error("GH must not be called without a number")
			}
		})
	}
}

func TestStartReviewRoutes(t *testing.T) {
	m := &mockAPI{}
	res, err := deps(m).startReview(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotNumber != 3 || res.(*github.StartReview).ReviewID != "PRR_1" {
		t.Errorf("start_review not forwarded: number=%d res=%+v", m.gotNumber, res)
	}
}

func TestSubmitReviewRoutes(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).submitReview(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3,"review_id":"PRR_1","event":"APPROVE","body":"lgtm"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotReviewID != "PRR_1" || m.gotEvent != "APPROVE" {
		t.Errorf("submit_review not forwarded: id=%q event=%q", m.gotReviewID, m.gotEvent)
	}
}

func TestSubmitReviewValidation(t *testing.T) {
	cases := map[string]string{
		"missing review_id": `{"owner":"o","repo":"r","number":3,"event":"APPROVE"}`,
		"missing event":     `{"owner":"o","repo":"r","number":3,"review_id":"PRR_1"}`,
		"bad event":         `{"owner":"o","repo":"r","number":3,"review_id":"PRR_1","event":"MERGE"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			m := &mockAPI{}
			_, err := deps(m).submitReview(context.Background(), json.RawMessage(body))
			wantBadRequest(t, err)
			if m.called {
				t.Error("GH must not be called on invalid input")
			}
		})
	}
}

func TestDiscardReviewRoutes(t *testing.T) {
	m := &mockAPI{}
	res, err := deps(m).discardReview(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3,"review_id":"PRR_1"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotReviewID != "PRR_1" {
		t.Errorf("discard_review id not forwarded: %q", m.gotReviewID)
	}
	if b, _ := json.Marshal(res); string(b) != "{}" {
		t.Errorf("discard_review should return {}, got %s", b)
	}
}

func TestDiscardReviewRequiresReviewID(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).discardReview(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3}`))
	wantBadRequest(t, err)
	if m.called {
		t.Error("GH must not be called without a review_id")
	}
}

func TestPostCommentRoutes(t *testing.T) {
	m := &mockAPI{}
	res, err := deps(m).postComment(context.Background(), json.RawMessage(
		`{"owner":"o","repo":"r","number":3,"path":"a.go","side":"RIGHT","line":8,"start_line":4,"body":"nit","review_id":"PRR_1"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotComment.Path != "a.go" || m.gotComment.StartLine != 4 || m.gotComment.ReviewID != "PRR_1" {
		t.Errorf("params not forwarded: %+v", m.gotComment)
	}
	if pc := res.(*github.PostComment); pc.ID != 555 || pc.ThreadID != "PRT_1" {
		t.Errorf("result not forwarded: %+v", pc)
	}
}

// a reply skips anchor validation: only body and in_reply_to are needed.
func TestPostCommentReplyRoutes(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).postComment(context.Background(), json.RawMessage(
		`{"owner":"o","repo":"r","number":3,"in_reply_to":"PRT_5","body":"thanks"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotComment.InReplyTo != "PRT_5" {
		t.Errorf("reply not forwarded: %+v", m.gotComment)
	}
}

func TestResolveThreadRoutes(t *testing.T) {
	m := &mockAPI{}
	res, err := deps(m).resolveThread(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3,"thread_id":"PRT_7","resolved":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotThreadID != "PRT_7" || !m.gotResolved {
		t.Errorf("params not forwarded: id=%q resolved=%v", m.gotThreadID, m.gotResolved)
	}
	if res.(*github.ResolveThread).Resolved != true {
		t.Errorf("result not forwarded: %+v", res)
	}
}

func TestResolveThreadRequiresThreadID(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).resolveThread(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3,"resolved":false}`))
	wantBadRequest(t, err)
	if m.called {
		t.Error("GH must not be called without a thread_id")
	}
}

func TestSetFileViewedRoutes(t *testing.T) {
	m := &mockAPI{}
	res, err := deps(m).setFileViewed(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3,"path":"a.go","viewed":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.gotPath != "a.go" || !m.gotViewed {
		t.Errorf("params not forwarded: path=%q viewed=%v", m.gotPath, m.gotViewed)
	}
	if res.(*github.SetFileViewed).ViewedState != "VIEWED" {
		t.Errorf("result not forwarded: %+v", res)
	}
}

func TestSetFileViewedRequiresPath(t *testing.T) {
	m := &mockAPI{}
	_, err := deps(m).setFileViewed(context.Background(), json.RawMessage(`{"owner":"o","repo":"r","number":3,"viewed":true}`))
	wantBadRequest(t, err)
	if m.called {
		t.Error("GH must not be called without a path")
	}
}

func TestPostCommentValidation(t *testing.T) {
	cases := map[string]string{
		"missing body":       `{"owner":"o","repo":"r","number":3,"path":"a.go","side":"RIGHT","line":8}`,
		"missing path":       `{"owner":"o","repo":"r","number":3,"side":"RIGHT","line":8,"body":"x"}`,
		"bad side":           `{"owner":"o","repo":"r","number":3,"path":"a.go","side":"MIDDLE","line":8,"body":"x"}`,
		"non-positive line":  `{"owner":"o","repo":"r","number":3,"path":"a.go","side":"RIGHT","line":0,"body":"x"}`,
		"range start >= end": `{"owner":"o","repo":"r","number":3,"path":"a.go","side":"RIGHT","line":4,"start_line":4,"body":"x"}`,
		"bad start_side":     `{"owner":"o","repo":"r","number":3,"path":"a.go","side":"RIGHT","line":8,"start_line":4,"start_side":"UP","body":"x"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			m := &mockAPI{}
			_, err := deps(m).postComment(context.Background(), json.RawMessage(body))
			wantBadRequest(t, err)
			if m.called {
				t.Error("GH must not be called on invalid input")
			}
		})
	}
}
