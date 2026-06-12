// dipher-sidecar speaks newline-delimited JSON over stdio to the Lua client.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

const protocolVersion = 1

const binaryVersion = "0.1.0"

type request struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type response struct {
	ID     int       `json:"id"`
	Result any       `json:"result,omitempty"`
	Error  *rpcError `json:"error,omitempty"`
}

type rpcError struct {
	Code       string `json:"code"`
	Message    string `json:"message"`
	RetryAfter int    `json:"retry_after,omitempty"`
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "dipher-sidecar:", err)
		os.Exit(1)
	}
}

// run reads requests line by line and writes one response per request.
func run(in *os.File, out *os.File) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	enc := json.NewEncoder(out)

	for scanner.Scan() {
		var req request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			_ = enc.Encode(response{Error: &rpcError{Code: "bad_request", Message: "invalid JSON"}})
			continue
		}
		_ = enc.Encode(dispatch(req))
	}
	return scanner.Err()
}

// dispatch routes a request to its handler.
func dispatch(req request) response {
	switch req.Method {
	case "hello":
		return response{ID: req.ID, Result: map[string]any{
			"protocol": protocolVersion,
			"binary":   binaryVersion,
		}}
	default:
		// TODO: list_prs, get_pr, get_file_versions, get_threads, post_comment, submit_review
		return response{ID: req.ID, Error: &rpcError{
			Code:    "bad_request",
			Message: "unknown method: " + req.Method,
		}}
	}
}
