package github

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

const maxResponse = 32 * 1024 * 1024 // bound a single response body

// getJSON does an authenticated REST GET, maps the status to a protocol code, and
// decodes the body into out.
func (c *Client) getJSON(ctx context.Context, rawURL string, out any) error {
	if c.tokenErr != nil {
		return c.tokenErr
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}
	c.setRESTHeaders(req)

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
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(body, out); err != nil {
		return protocol.NewError(protocol.CodeInternal, "decoding response: "+err.Error())
	}
	return nil
}

// postJSON does an authenticated REST POST with a JSON body, maps the status to a
// protocol code, and decodes the response into out (out may be nil to discard it).
func (c *Client) postJSON(ctx context.Context, rawURL string, payload, out any) error {
	if c.tokenErr != nil {
		return c.tokenErr
	}
	buf, err := json.Marshal(payload)
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, rawURL, bytes.NewReader(buf))
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}
	c.setRESTHeaders(req)
	req.Header.Set("Content-Type", "application/json")

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
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(body, out); err != nil {
		return protocol.NewError(protocol.CodeInternal, "decoding response: "+err.Error())
	}
	return nil
}

// getPaged follows the REST Link rel="next" header, decoding each page into a
// []T and appending. it caps pages defensively so a runaway never spins forever.
func getPaged[T any](ctx context.Context, c *Client, rawURL string) ([]T, error) {
	if c.tokenErr != nil {
		return nil, c.tokenErr
	}
	const maxPages = 100
	var all []T
	for page := 0; rawURL != "" && page < maxPages; page++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return nil, protocol.NewError(protocol.CodeInternal, err.Error())
		}
		c.setRESTHeaders(req)

		resp, err := c.http.Do(req)
		if perr := mapHTTP(resp, nil, err); perr != nil {
			return nil, perr
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxResponse))
		next := nextLink(resp.Header.Get("Link"))
		_ = resp.Body.Close()

		if perr := mapHTTP(resp, body, nil); perr != nil {
			return nil, perr
		}
		if readErr != nil {
			return nil, protocol.NewError(protocol.CodeNetwork, "reading response: "+readErr.Error())
		}
		var pageItems []T
		if err := json.Unmarshal(body, &pageItems); err != nil {
			return nil, protocol.NewError(protocol.CodeInternal, "decoding response: "+err.Error())
		}
		all = append(all, pageItems...)
		rawURL = next
	}
	return all, nil
}

func (c *Client) setRESTHeaders(req *http.Request) {
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", apiVersion)
}

var linkNextRe = regexp.MustCompile(`<([^>]+)>\s*;\s*rel="next"`)

// nextLink extracts the rel="next" URL from a REST Link header, "" if absent.
func nextLink(header string) string {
	m := linkNextRe.FindStringSubmatch(header)
	if len(m) == 2 {
		return m[1]
	}
	return ""
}

// query builds an escaped query string.
func query(kv map[string]string) string {
	v := url.Values{}
	for k, val := range kv {
		v.Set(k, val)
	}
	return v.Encode()
}
