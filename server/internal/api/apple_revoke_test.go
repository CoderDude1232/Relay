package api

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/relayapp/relay-server/internal/siwa"
)

// TestDeleteAccountRevokesSignInWithApple: DELETE /v1/accounts/me with an
// appleAuthorizationCode exchanges and revokes it at (a fake) Apple; Apple
// failing never fails the deletion; without a code Apple isn't called.
func TestDeleteAccountRevokesSignInWithApple(t *testing.T) {
	env := newTestEnv(t)
	var mu sync.Mutex
	var calls []string
	appleDown := false
	apple := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		mu.Lock()
		calls = append(calls, r.URL.Path+":"+r.PostForm.Get("code")+r.PostForm.Get("token"))
		down := appleDown
		mu.Unlock()
		if down {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if r.URL.Path == "/auth/token" {
			w.Write([]byte(`{"access_token":"at","refresh_token":"rt-xyz"}`))
		}
	}))
	t.Cleanup(apple.Close)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	revoker, err := siwa.NewWithKey(key, "KEY123", "TEAM123", "app.relaymsg")
	if err != nil {
		t.Fatal(err)
	}
	revoker.HTTP = apple.Client()
	revoker.TokenURL = apple.URL + "/auth/token"
	revoker.RevokeURL = apple.URL + "/auth/revoke"
	env.api.SetAppleRevoker(revoker)

	reset := func() []string {
		mu.Lock()
		defer mu.Unlock()
		out := calls
		calls = nil
		return out
	}

	// With a code: exchanged, then the refresh token revoked.
	a := env.register("siwa-a", "password-a")
	env.doJSON("DELETE", "/v1/accounts/me", a.authUser(), a.password,
		map[string]string{"appleAuthorizationCode": "code-abc"}, http.StatusNoContent, nil)
	if got := reset(); len(got) != 2 || got[0] != "/auth/token:code-abc" || got[1] != "/auth/revoke:rt-xyz" {
		t.Fatalf("apple calls = %v", got)
	}

	// Apple down: the account is still deleted.
	mu.Lock()
	appleDown = true
	mu.Unlock()
	b := env.register("siwa-b", "password-b")
	env.doJSON("DELETE", "/v1/accounts/me", b.authUser(), b.password,
		map[string]string{"appleAuthorizationCode": "code-def"}, http.StatusNoContent, nil)
	if exists, _ := env.api.store.AccountExists(b.accountID); exists {
		t.Fatal("account survived a failed Apple revocation")
	}
	mu.Lock()
	appleDown = false
	mu.Unlock()
	reset()

	// No body / no code: Apple isn't contacted.
	c := env.register("siwa-c", "password-c")
	env.doJSON("DELETE", "/v1/accounts/me", c.authUser(), c.password, nil, http.StatusNoContent, nil)
	if got := reset(); len(got) != 0 {
		t.Fatalf("apple called without a code: %v", got)
	}

	// A malformed body is rejected before anything is deleted.
	d := env.register("siwa-d", "password-d")
	env.doJSON("DELETE", "/v1/accounts/me", d.authUser(), d.password, []int{1}, http.StatusBadRequest, nil)
	if exists, _ := env.api.store.AccountExists(d.accountID); !exists {
		t.Fatal("account deleted despite a malformed body")
	}
}
