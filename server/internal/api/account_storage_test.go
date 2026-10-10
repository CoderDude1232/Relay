package api

import (
	"encoding/base64"
	"net/http"
	"testing"
)

func TestAccountStorage(t *testing.T) {
	env := newTestEnv(t)
	c := env.register("store-acct", "password-store")
	other := env.register("store-other", "password-other")

	env.doJSON("GET", "/v1/accounts/me/storage", c.authUser(), c.password, nil, http.StatusNotFound, nil)
	put := func(cl *client, blob string, base int64, want int) int64 {
		var r struct {
			Version int64 `json:"version"`
		}
		var out any
		if want == http.StatusOK {
			out = &r
		}
		env.doJSON("PUT", "/v1/accounts/me/storage", cl.authUser(), cl.password,
			map[string]any{"blob": base64.StdEncoding.EncodeToString([]byte(blob)), "baseVersion": base}, want, out)
		return r.Version
	}
	v1 := put(c, "ciphertext-1", 0, http.StatusOK)
	put(c, "ciphertext-x", 0, http.StatusConflict) // already exists
	v2 := put(c, "ciphertext-2", v1, http.StatusOK)
	put(c, "ciphertext-y", v1, http.StatusConflict) // stale base
	if v2 != v1+1 {
		t.Fatalf("versions: %d then %d", v1, v2)
	}
	var got struct {
		Blob    string `json:"blob"`
		Version int64  `json:"version"`
	}
	env.doJSON("GET", "/v1/accounts/me/storage", c.authUser(), c.password, nil, http.StatusOK, &got)
	if b, _ := base64.StdEncoding.DecodeString(got.Blob); string(b) != "ciphertext-2" || got.Version != v2 {
		t.Fatalf("got %q v%d", b, got.Version)
	}
	// Another account sees only its own (none).
	env.doJSON("GET", "/v1/accounts/me/storage", other.authUser(), other.password, nil, http.StatusNotFound, nil)
	// Deleting the account removes it.
	env.doJSON("DELETE", "/v1/accounts/me", c.authUser(), c.password, nil, http.StatusNoContent, nil)
	if _, _, err := env.api.store.AccountStorage(c.accountID); err == nil {
		t.Fatal("account storage survived account deletion")
	}
}
