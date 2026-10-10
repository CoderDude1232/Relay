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
	for _, c := range []*client{demo1, demo2} {
		if err := env.api.store.SetDemoAccount(c.accountID, true); err != nil {
			t.Fatal(err)
		}
	}
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()

	// Isolation: no key fetches across the line, either way; demo↔demo works.
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
