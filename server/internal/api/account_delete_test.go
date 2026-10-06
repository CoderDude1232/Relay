package api

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"testing"
	"time"
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

	// Credentials no longer authenticate.
	env.doJSON("GET", "/v1/keys/count", alice.authUser(), alice.password, nil, http.StatusUnauthorized, nil)
	env.doJSON("DELETE", "/v1/accounts/me", alice.authUser(), alice.password, nil, http.StatusUnauthorized, nil)

	// Username is released and can be registered again.
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
