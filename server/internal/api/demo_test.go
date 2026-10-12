package api

import (
	"net/http"
	"testing"
)

func TestDemoAccounts(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("alice-demo", "password-alice")
	demo1 := env.register("demo-one", "password-demo1")
	demo2 := env.register("demo-two", "password-demo2")
	for _, c := range []*client{alice, demo1, demo2} {
		c.uploadKeys(2)
	}
	if err := env.api.store.SetAccessKey(demo1.accountID, make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	for _, c := range []*client{demo1, demo2} {
		if err := env.api.store.SetDemoAccount(c.accountID, true); err != nil {
			t.Fatal(err)
		}
	}
	// An access key learned before the account became a demo account stops
	// opening the sealed paths.
	if k, _ := env.api.store.AccessKey(demo1.accountID); len(k) != 0 {
		t.Fatal("marking an account demo kept its access key")
	}
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()

	// Isolation: no key fetches across the line in either direction; demo to demo works.
	env.doJSON("GET", "/v1/keys/"+demo1.accountID, alice.authUser(), alice.password, nil, http.StatusNotFound, nil)
	env.doJSON("GET", "/v1/keys/"+alice.accountID, demo1.authUser(), demo1.password, nil, http.StatusNotFound, nil)
	env.doJSON("GET", "/v1/keys/"+demo2.accountID, demo1.authUser(), demo1.password, nil, http.StatusOK, nil)
	env.doJSON("GET", "/v1/keys/"+alice.accountID, alice.authUser(), alice.password, nil, http.StatusOK, nil)

	// Locked credentials and no email discovery.
	env.doJSON("PUT", "/v1/accounts/me/username", demo1.authUser(), demo1.password,
		map[string]string{"username": "demo_renamed"}, http.StatusForbidden, nil)
	env.doJSON("PUT", "/v1/accounts/me/account-password", demo1.authUser(), demo1.password,
		map[string]string{"accountPassword": "new-password-123"}, http.StatusForbidden, nil)
	env.doJSON("PUT", "/v1/accounts/me/discoverability", demo1.authUser(), demo1.password,
		map[string]bool{"email": true}, http.StatusForbidden, nil)

	// Delete resets instead: the device is gone, the account stays a demo account.
	env.doJSON("DELETE", "/v1/accounts/me", demo1.authUser(), demo1.password, nil, http.StatusNoContent, nil)
	env.doJSON("GET", "/v1/keys/count", demo1.authUser(), demo1.password, nil, http.StatusUnauthorized, nil)
	if demo, err := env.api.store.IsDemoAccount(demo1.accountID); err != nil || !demo {
		t.Fatalf("demo account should survive deletion as a demo account: demo=%v err=%v", demo, err)
	}
}

func TestDemoSignInAndStatus(t *testing.T) {
	env := newTestEnv(t)
	a := env.register("rv-a", "password-a")
	b := env.register("rv-b", "password-b")
	normal := env.register("rv-normal", "password-n")
	for _, c := range []*client{a, b} {
		if err := env.api.store.SetDemoAccount(c.accountID, true); err != nil {
			t.Fatal(err)
		}
	}
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()

	// Off until a code is configured; wrong code refused; right code (any case) works.
	env.doJSON("POST", "/v1/accounts/demo-signin", "", "", map[string]string{"code": "x"}, http.StatusUnauthorized, nil)
	env.api.SetDemoCode("Review-Code-123\n")
	env.doJSON("POST", "/v1/accounts/demo-signin", "", "", map[string]string{"code": "wrong"}, http.StatusUnauthorized, nil)
	var resp struct {
		AccountID string `json:"accountId"`
		Username  string `json:"username"`
	}
	env.doJSON("POST", "/v1/accounts/demo-signin", "", "", map[string]string{"code": "review-code-123"}, http.StatusCreated, &resp)
	if demo, err := env.api.store.IsDemoAccount(resp.AccountID); err != nil || !demo {
		t.Fatalf("demo sign-in landed on a non-demo account: %+v", resp)
	}
	if resp.AccountID == normal.accountID {
		t.Fatal("demo sign-in must never reach a normal account")
	}

	// Status: demo with the other demo account as peer; normal accounts see nothing.
	var st struct {
		Demo  bool     `json:"demo"`
		Peers []string `json:"peers"`
	}
	env.doJSON("GET", "/v1/accounts/me/demo", b.authUser(), b.password, nil, http.StatusOK, &st)
	hasA := false
	for _, p := range st.Peers {
		if p == a.username {
			hasA = true
		}
		if p == b.username || p == normal.username {
			t.Fatalf("peers must be other demo accounts only: %v", st.Peers)
		}
	}
	if !st.Demo || !hasA {
		t.Fatalf("demo status for b: %+v (want peer %s)", st, a.username)
	}
	env.doJSON("GET", "/v1/accounts/me/demo", normal.authUser(), normal.password, nil, http.StatusOK, &st)
	if st.Demo || len(st.Peers) != 0 {
		t.Fatalf("normal account should not be demo: %+v", st)
	}
}
