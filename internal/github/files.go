package github

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

// GetFileVersions returns the full base and head blobs for one path in a PR. it
// resolves the PR's base/head SHA, then fetches each side via the Contents API raw
// media type; a 404 on a side marks it missing (an added file has no base, a
// deleted file has no head) rather than failing the call.
func (c *Client) GetFileVersions(ctx context.Context, owner, repo string, number int, path string) (*FileVersions, error) {
	base, head, err := c.prRefs(ctx, owner, repo, number)
	if err != nil {
		return nil, err
	}
	baseBlob, err := c.rawBlob(ctx, owner, repo, path, base)
	if err != nil {
		return nil, err
	}
	headBlob, err := c.rawBlob(ctx, owner, repo, path, head)
	if err != nil {
		return nil, err
	}
	return &FileVersions{Base: baseBlob, Head: headBlob}, nil
}

// prRefs resolves a PR's base and head commit SHAs via REST (lighter than the
// get_pr GraphQL meta, which fetches the whole file list).
func (c *Client) prRefs(ctx context.Context, owner, repo string, number int) (base, head string, err error) {
	var p prRefsDTO
	rawURL := c.restURL + "/repos/" + owner + "/" + repo + "/pulls/" + strconv.Itoa(number)
	if err := c.getJSON(ctx, rawURL, &p); err != nil {
		return "", "", err
	}
	return p.Base.SHA, p.Head.SHA, nil
}

// rawBlob fetches a path's bytes at ref via the Contents API raw media type. a 404
// means the path is absent at that ref, reported as Missing rather than an error.
// ref is a commit sha, so the result is immutable and cached forever (§7.5).
func (c *Client) rawBlob(ctx context.Context, owner, repo, path, ref string) (FileBlob, error) {
	if c.tokenErr != nil {
		return FileBlob{}, c.tokenErr
	}
	key := blobKey(owner, repo, ref, path)
	if b, ok := c.cache.blob(key); ok {
		return b, nil
	}
	rawURL := c.restURL + "/repos/" + owner + "/" + repo + "/contents/" + escapePath(path) + "?ref=" + url.QueryEscape(ref)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return FileBlob{}, protocol.NewError(protocol.CodeInternal, err.Error())
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github.raw+json")
	req.Header.Set("X-GitHub-Api-Version", apiVersion)

	resp, err := c.http.Do(req)
	if err != nil {
		return FileBlob{}, protocol.NewError(protocol.CodeNetwork, "network error: "+err.Error())
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusNotFound {
		// a missing path at a sha is itself immutable, so cache it too.
		blob := FileBlob{Missing: true}
		c.cache.putBlob(key, blob)
		return blob, nil
	}
	body, rerr := io.ReadAll(io.LimitReader(resp.Body, maxResponse))
	if perr := mapHTTP(resp, body, nil); perr != nil {
		return FileBlob{}, perr
	}
	if rerr != nil {
		return FileBlob{}, protocol.NewError(protocol.CodeNetwork, "reading response: "+rerr.Error())
	}
	blob := FileBlob{Content: string(body)}
	c.cache.putBlob(key, blob)
	return blob, nil
}

// escapePath percent-escapes each segment of a repo-relative path, keeping the
// slashes the Contents API uses as path separators.
func escapePath(p string) string {
	parts := strings.Split(p, "/")
	for i, s := range parts {
		parts[i] = url.PathEscape(s)
	}
	return strings.Join(parts, "/")
}
