package github

// client-facing result shapes. these track the frozen §7.3 contract and must not
// drift; the github wire shapes they are built from live in dtos.go.

// PR is one row in the list_prs result.
type PR struct {
	Number    int    `json:"number"`
	Title     string `json:"title"`
	Author    string `json:"author"`
	HeadRef   string `json:"head_ref"`
	UpdatedAt string `json:"updated_at"`
	Draft     bool   `json:"draft"`
}

// PRDetail is the get_pr result.
type PRDetail struct {
	Title     string   `json:"title"`
	Body      string   `json:"body"`
	Author    string   `json:"author"`
	BaseSHA   string   `json:"base_sha"`
	HeadSHA   string   `json:"head_sha"`
	HeadRef   string   `json:"head_ref"`
	URL       string   `json:"url"`
	State     string   `json:"state"`
	Draft     bool     `json:"draft"`
	Mergeable string   `json:"mergeable"`
	Files     []PRFile `json:"files"`
}

// PRFile is one changed file in a PRDetail. ViewedState is VIEWED/DISMISSED/UNVIEWED.
type PRFile struct {
	Path         string `json:"path"`
	Status       string `json:"status"`
	Additions    int    `json:"additions"`
	Deletions    int    `json:"deletions"`
	PreviousPath string `json:"previous_path,omitempty"`
	ViewedState  string `json:"viewed_state"`
}

// FileVersions is the get_file_versions result: the full base and head blobs for
// one path. Truncated is reserved for the large-file streaming path; full blobs
// leave it false.
type FileVersions struct {
	Base      FileBlob `json:"base"`
	Head      FileBlob `json:"head"`
	Truncated bool     `json:"truncated,omitempty"`
}

// FileBlob is one side's content; Missing marks a path absent at that ref (an
// added file has no base, a deleted file has no head).
type FileBlob struct {
	Content string `json:"content"`
	Missing bool   `json:"missing,omitempty"`
}

// Thread is one review thread in the get_threads result. ID is the root comment's
// numeric id (the reply anchor); ThreadID is the GraphQL node id resolve_thread
// operates on. Side/StartSide are LEFT/RIGHT (§6.2); StartSide/StartLine are set
// only on range threads. IsPending is true for an unsubmitted draft thread.
type Thread struct {
	ID        int64           `json:"id"`
	ThreadID  string          `json:"thread_id"`
	Path      string          `json:"path"`
	Side      string          `json:"side"`
	Line      int             `json:"line"`
	StartSide string          `json:"start_side,omitempty"`
	StartLine int             `json:"start_line,omitempty"`
	Resolved  bool            `json:"resolved"`
	IsPending bool            `json:"is_pending"`
	Comments  []ThreadComment `json:"comments"`
}

// ThreadComment is one comment in a Thread. ID is the numeric comment id.
type ThreadComment struct {
	ID        int64  `json:"id"`
	Author    string `json:"author"`
	Body      string `json:"body"`
	CreatedAt string `json:"created_at"`
}

// PendingReview is the get_pending_review result; ReviewID is nil when the viewer
// has no draft, otherwise the GraphQL review node id submit/discard operate on.
type PendingReview struct {
	ReviewID *string          `json:"review_id"`
	Comments []PendingComment `json:"comments,omitempty"`
}

// PendingComment is one draft comment in a PendingReview, carrying enough anchor
// to restore cursor position on resume.
type PendingComment struct {
	ID        int64  `json:"id"`
	Path      string `json:"path"`
	Side      string `json:"side"`
	Line      int    `json:"line"`
	StartSide string `json:"start_side,omitempty"`
	StartLine int    `json:"start_line,omitempty"`
	Body      string `json:"body"`
}

// Checks is the get_checks result: the overall rollup state plus each check.
type Checks struct {
	Rollup string  `json:"rollup"`
	Checks []Check `json:"checks"`
}

// Check is one normalised rollup entry (a CheckRun or a legacy StatusContext).
type Check struct {
	Name       string `json:"name"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	URL        string `json:"url"`
	StartedAt  string `json:"started_at,omitempty"`
}

// PostCommentInput carries the post_comment params into the github layer. InReplyTo
// (a thread node id) selects the reply path; otherwise a new thread is opened, as a
// draft when ReviewID is set or immediately when it isn't. Side/StartSide are
// LEFT/RIGHT; StartLine/StartSide anchor the start of a multi-line range.
type PostCommentInput struct {
	Path      string
	Side      string
	Line      int
	Body      string
	StartSide string
	StartLine int
	InReplyTo string
	ReviewID  string
}

// PostComment is the post_comment result: the new comment's numeric id and the node
// id of the thread it belongs to (the same thread on a reply).
type PostComment struct {
	ID       int64  `json:"id"`
	ThreadID string `json:"thread_id"`
}

// StartReview is the start_review result: the pending review's node id (a fresh
// one, or the viewer's existing draft when start_review is replayed).
type StartReview struct {
	ReviewID string `json:"review_id"`
}

// SubmitReview is the submit_review result: the finalized review's numeric id.
type SubmitReview struct {
	ID int64 `json:"id"`
}
