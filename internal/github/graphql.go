package github

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

// graphql posts a raw GraphQL query (§7.5: no go-gh, no typed dep) and decodes
// the data field into out. top-level GraphQL errors map via mapGraphQL even on a
// 200; HTTP-level failures map via mapHTTP.
func (c *Client) graphql(ctx context.Context, query string, vars map[string]any, out any) error {
	if c.tokenErr != nil {
		return c.tokenErr
	}
	payload, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.gqlURL, bytes.NewReader(payload))
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", apiVersion)

	resp, err := c.http.Do(req)
	if perr := mapHTTP(resp, nil, err); perr != nil {
		return perr
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponse))
	if err != nil {
		return protocol.NewError(protocol.CodeNetwork, "reading response: "+err.Error())
	}
	if perr := mapHTTP(resp, body, nil); perr != nil {
		return perr
	}

	var envelope struct {
		Data   json.RawMessage `json:"data"`
		Errors []gqlError      `json:"errors"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return protocol.NewError(protocol.CodeInternal, "decoding graphql response: "+err.Error())
	}
	if perr := mapGraphQL(envelope.Errors); perr != nil {
		return perr
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(envelope.Data, out); err != nil {
		return protocol.NewError(protocol.CodeInternal, "decoding graphql data: "+err.Error())
	}
	return nil
}
