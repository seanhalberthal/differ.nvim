package handlers

import (
	"context"
	"encoding/json"
	"strconv"

	"github.com/seanhalberthal/dipher.nvim/internal/protocol"
)

type helloParams struct {
	Client   string `json:"client"`
	Protocol int    `json:"protocol"`
}

type helloResult struct {
	Protocol int    `json:"protocol"`
	Binary   string `json:"binary"`
}

// hello is the handshake (§7.2). a client protocol newer than ours is a hard
// mismatch surfaced as bad_request so the client tells the user to rebuild; an
// older or unset client protocol still gets our versions back.
func (d Deps) hello(_ context.Context, params json.RawMessage) (any, error) {
	var p helloParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.Protocol > protocol.Version {
		return nil, protocol.NewError(protocol.CodeBadRequest,
			"protocol mismatch: client speaks "+strconv.Itoa(p.Protocol)+
				", sidecar speaks "+strconv.Itoa(protocol.Version)+", rebuild your sidecar (:Dipher build)")
	}
	return helloResult{Protocol: protocol.Version, Binary: protocol.Binary}, nil
}
