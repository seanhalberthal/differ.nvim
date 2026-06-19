package github

import (
	"os"
	"os/exec"
	"strings"

	"github.com/seanhalberthal/differ.nvim/internal/protocol"
)

// ResolveToken finds a GitHub token without go-gh: GH_TOKEN, then
// GITHUB_TOKEN, then `gh auth token`. a missing gh binary with no env token is
// gh_missing; gh present but yielding no token is auth. the token is never logged.
func ResolveToken() (string, error) {
	for _, env := range []string{"GH_TOKEN", "GITHUB_TOKEN"} {
		if v := strings.TrimSpace(os.Getenv(env)); v != "" {
			return v, nil
		}
	}

	gh, err := exec.LookPath("gh")
	if err != nil {
		return "", protocol.NewError(protocol.CodeGHMissing,
			"no token in GH_TOKEN/GITHUB_TOKEN and the gh CLI is not installed")
	}

	out, err := exec.Command(gh, "auth", "token").Output()
	if err != nil {
		return "", protocol.NewError(protocol.CodeAuth,
			"gh is installed but not authenticated; run `gh auth login`")
	}
	token := strings.TrimSpace(string(out))
	if token == "" {
		return "", protocol.NewError(protocol.CodeAuth, "gh returned an empty token; run `gh auth login`")
	}
	return token, nil
}
