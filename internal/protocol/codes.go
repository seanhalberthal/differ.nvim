package protocol

// the closed set of error codes (§7.1). nothing outside this set ever reaches
// the client: the github layer maps I/O failures into these, handlers produce
// only bad_request/conflict, and anything unmapped falls back to internal.
const (
	CodeAuth        = "auth"
	CodeNotFound    = "not_found"
	CodeRateLimited = "rate_limited"
	CodeNetwork     = "network"
	CodeGHMissing   = "gh_missing"
	CodeInternal    = "internal"
	CodeBadRequest  = "bad_request"
	CodeConflict    = "conflict"
)

// Error is a typed error carrying a protocol code. handlers and the github layer
// return it; dispatch unwraps it via errors.As into an RPCError envelope.
type Error struct {
	Code       string
	Message    string
	RetryAfter int
}

func (e *Error) Error() string { return e.Message }

// NewError builds a coded error.
func NewError(code, message string) *Error {
	return &Error{Code: code, Message: message}
}

// RateLimited builds a rate_limited error with a retry hint (seconds).
func RateLimited(message string, retryAfter int) *Error {
	return &Error{Code: CodeRateLimited, Message: message, RetryAfter: retryAfter}
}
