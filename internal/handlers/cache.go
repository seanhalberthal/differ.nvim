package handlers

import (
	"context"
	"encoding/json"
)

// cacheClearer is the optional capability the cache_clear handler reaches for; the
// real *github.Client satisfies it. kept here (consumer-side) so handlers don't
// depend on the cache's concrete type.
type cacheClearer interface {
	ClearCache()
}

// cacheClear flushes the sidecar's caches, surfaced as :Differ cache clear.
// it is a no-op when the backend has no cache (e.g. a test double).
func (d Deps) cacheClear(_ context.Context, _ json.RawMessage) (any, error) {
	if cc, ok := d.GH.(cacheClearer); ok {
		cc.ClearCache()
	}
	return struct{}{}, nil
}
