package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/oprf"
)

func uniqueUsername(prefix string) string {
	var b [4]byte
	rand.Read(b[:])
	return prefix + "-" + hex.EncodeToString(b[:])
}

// TestDeleteAccount: an account deletes itself; its live WebSocket is closed,
// its credentials stop authenticating, and its username is free again.
func TestDeleteAccount(t *testing.T) {
	env := newTestEnv(t)
	name := uniqueUsername("delme")
	alice := env.registerAs(name, "password-alice")
	alice.uploadKeys(5)
	ws := alice.connectWS()

	env.doJSON("DELETE", "/v1/accounts/me", alice.authUser(), alice.password, nil, http.StatusNoContent, nil)

	// The live socket is torn down by the server.
	ws.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, _, err := ws.conn.ReadMessage(); err == nil {
		t.Fatal("websocket still open after account deletion")
	} else if strings.Contains(err.Error(), "timeout") {
		t.Fatalf("websocket was not closed: %v", err)
	}

	// Its credentials stop authenticating.
	env.doJSON("GET", "/v1/keys/count", alice.authUser(), alice.password, nil, http.StatusUnauthorized, nil)
	env.doJSON("DELETE", "/v1/accounts/me", alice.authUser(), alice.password, nil, http.StatusUnauthorized, nil)

	// Without a release key (no OPRF) there is no reuse cooldown: the
	// username is released and can be registered again right away.
	var avail struct {
		Available bool `json:"available"`
	}
	env.doJSON("GET", "/v1/usernames/"+name+"/available", "", "", nil, http.StatusOK, &avail)
	if !avail.Available {
		t.Fatal("deleted account's username is still reported taken")
	}
	again := env.registerAs(name, "password-again")
	if again.accountID == alice.accountID {
		t.Fatal("re-registration reused the deleted account id")
	}
}

// TestDeleteAccountRetriesSupabaseDeletion: when Supabase can't be reached at
// deletion time the linked user stays queued, and a later retry deletes it.
func TestDeleteAccountRetriesSupabaseDeletion(t *testing.T) {
	env := newTestEnv(t)
	stubSupabase(env)
	var mu sync.Mutex
	down := true
	var deleted []string
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Method != http.MethodDelete || !strings.HasPrefix(r.URL.Path, "/auth/v1/admin/users/") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if down {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		deleted = append(deleted, strings.TrimPrefix(r.URL.Path, "/auth/v1/admin/users/"))
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(admin.Close)
	env.api.SetSupabaseAuth(admin.URL, "anon")
	env.api.SetSupabaseServiceKey("service")

	sfx := uniqueUsername("")
	uid := "del-u" + sfx
	name := "delsb" + strings.ReplaceAll(sfx, "-", "")
	var resp struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
	}
	env.doJSON("POST", "/v1/accounts", "", "", map[string]string{
		"username": name, "password": "device-pw-1", "supabaseAccessToken": uid + "|d" + sfx + "@x.com|0",
	}, http.StatusCreated, &resp)
	c := &client{env: env, username: name, accountID: resp.AccountID, deviceID: resp.DeviceID, password: "device-pw-1"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	// Supabase is down: the account still goes, the user stays queued.
	env.doJSON("DELETE", "/v1/accounts/me", c.authUser(), c.password, nil, http.StatusNoContent, nil)
	pending := func() bool {
		ids, err := env.api.store.PendingSupabaseDeletions(1000)
		if err != nil {
			t.Fatal(err)
		}
		for _, id := range ids {
			if id == uid {
				return true
			}
		}
		return false
	}
	if !pending() {
		t.Fatal("supabase user not queued after a failed delete")
	}

	mu.Lock()
	down = false
	mu.Unlock()
	env.api.RetrySupabaseDeletions(context.Background())
	mu.Lock()
	gotDeleted := strings.Join(deleted, ",")
	mu.Unlock()
	if !strings.Contains(gotDeleted, uid) {
		t.Fatalf("retry did not delete the supabase user (deleted %q)", gotDeleted)
	}
	if pending() {
		t.Fatal("supabase user still queued after a successful retry")
	}
}

// TestUsernameReuseCooldown: with the cooldown enabled (OPRF configured), a
// released username can't be taken by another account, neither after a
// rename nor after account deletion, while the renaming account may take its
// own old name back. Expiry is covered by the store test.
func TestUsernameReuseCooldown(t *testing.T) {
	env := newTestEnv(t)
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	available := func(name string) bool {
		var avail struct {
			Available bool `json:"available"`
		}
		env.doJSON("GET", "/v1/usernames/"+name+"/available", "", "", nil, http.StatusOK, &avail)
		return avail.Available
	}

	old := uniqueUsername("cool")
	alice := env.registerAs(old, "password-alice")
	bob := env.register("cool-bob", "password-bob")
	env.doJSON("PUT", "/v1/accounts/me/username", alice.authUser(), alice.password,
		map[string]string{"username": uniqueUsername("cool-new")}, http.StatusNoContent, nil)
	if available(old) || available(strings.ToUpper(old)) {
		t.Fatal("renamed-away username reported available during the cooldown")
	}
	env.doJSON("PUT", "/v1/accounts/me/username", bob.authUser(), bob.password,
		map[string]string{"username": old}, http.StatusConflict, nil)
	env.doJSON("POST", "/v1/accounts", "", "",
		map[string]string{"username": strings.ToUpper(old), "password": "password-carol"}, http.StatusConflict, nil)
	// The original owner may reclaim it.
	env.doJSON("PUT", "/v1/accounts/me/username", alice.authUser(), alice.password,
		map[string]string{"username": old}, http.StatusNoContent, nil)

	// Deleting the account blocks the name for everyone.
	env.doJSON("DELETE", "/v1/accounts/me", alice.authUser(), alice.password, nil, http.StatusNoContent, nil)
	if available(old) {
		t.Fatal("deleted account's username reported available during the cooldown")
	}
	env.doJSON("POST", "/v1/accounts", "", "",
		map[string]string{"username": old, "password": "password-dave"}, http.StatusConflict, nil)
}

// TestReports covers validation, success, and the deletion semantics: reports
// an account filed are removed with it; reports against it are kept.
func TestReports(t *testing.T) {
	env := newTestEnv(t)
	alice := env.registerAs(uniqueUsername("rep-alice"), "password-alice")
	bob := env.registerAs(uniqueUsername("rep-bob"), "password-bob")

	post := func(c *client, body map[string]any, want int) {
		t.Helper()
		env.doJSON("POST", "/v1/reports", c.authUser(), c.password, body, want, nil)
	}

	post(alice, map[string]any{"reportedAccount": bob.accountID, "reason": "bogus"}, http.StatusBadRequest)
	post(alice, map[string]any{"reportedAccount": alice.accountID, "reason": "spam"}, http.StatusBadRequest)
	post(alice, map[string]any{"reportedAccount": "00000000-0000-4000-8000-000000000000", "reason": "spam"}, http.StatusNotFound)
	post(alice, map[string]any{"reportedAccount": bob.accountID, "reason": "spam", "details": strings.Repeat("x", 2001)}, http.StatusBadRequest)
	post(alice, map[string]any{"reportedAccount": bob.accountID, "reason": "spam", "messages": make([]string, 11)}, http.StatusBadRequest)
	post(alice, map[string]any{"reportedAccount": bob.accountID, "reason": "spam", "messages": []string{strings.Repeat("y", 4001)}}, http.StatusBadRequest)

	post(alice, map[string]any{
		"reportedAccount": bob.accountID,
		"reason":          "harassment",
		"details":         "keeps messaging me",
		"messages":        []string{"forwarded message 1", "forwarded message 2"},
	}, http.StatusNoContent)
	post(bob, map[string]any{"reportedAccount": alice.accountID, "reason": "other"}, http.StatusNoContent)

	reports, err := env.api.store.ReportsAgainst(bob.accountID)
	if err != nil {
		t.Fatal(err)
	}
	if len(reports) != 1 || reports[0].ReporterAccount != alice.accountID || reports[0].Reason != "harassment" ||
		reports[0].Messages != `["forwarded message 1","forwarded message 2"]` {
		t.Fatalf("stored report: %+v", reports)
	}

	// Alice deletes her account: the report she filed goes, the one against her stays.
	env.doJSON("DELETE", "/v1/accounts/me", alice.authUser(), alice.password, nil, http.StatusNoContent, nil)
	if reports, _ := env.api.store.ReportsAgainst(bob.accountID); len(reports) != 0 {
		t.Fatalf("report filed by deleted account survived: %+v", reports)
	}
	if reports, _ := env.api.store.ReportsAgainst(alice.accountID); len(reports) != 1 {
		t.Fatalf("report against deleted account was removed: %+v", reports)
	}

	// Rate limit: 20 per reporter per 24h (bob has used 1).
	carol := env.registerAs(uniqueUsername("rep-carol"), "password-carol")
	for i := 0; i < 19; i++ {
		post(bob, map[string]any{"reportedAccount": carol.accountID, "reason": "spam"}, http.StatusNoContent)
	}
	post(bob, map[string]any{"reportedAccount": carol.accountID, "reason": "spam"}, http.StatusTooManyRequests)
}
