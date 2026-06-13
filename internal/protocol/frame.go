// Package protocol is the frozen wire contract (§7): newline-delimited JSON over stdio.
// it imports nothing internal so the contract stays a leaf and cannot drift.
package protocol

import "encoding/json"

// Request is one inbound frame: an integer id, a method name, and raw params
// decoded by the handler that owns the method.
type Request struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// Response is one outbound frame. exactly one of Result/Error is set.
type Response struct {
	ID     int       `json:"id"`
	Result any       `json:"result,omitempty"`
	Error  *RPCError `json:"error,omitempty"`
}

// RPCError is the failure payload; Code is from the closed set in codes.go.
type RPCError struct {
	Code       string `json:"code"`
	Message    string `json:"message"`
	RetryAfter int    `json:"retry_after,omitempty"`
}

// Outbound is anything the writer can serialize. v1 only has Response; phase 6
// adds a server→client notification frame without reworking the writer.
type Outbound interface{ outbound() }

func (Response) outbound() {}
