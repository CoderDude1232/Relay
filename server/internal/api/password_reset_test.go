package api

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/oprf"
)

func TestRecoveryAuthTime(t *testing.T) {
	enc := func(s string) string { return base64.RawURLEncoding.EncodeToString([]byte(s)) }
	ts := time.Now().Add(-2 * time.Minute).Unix()
	tok := enc(`{"alg":"none"}`) + "." + enc(fmt.Sprintf(`{"amr":[{"method":"password","timestamp":1},{"method":"recovery","timestamp":%d}]}`, ts)) + ".sig"
	if got := recoveryAuthTime(tok); got.Unix() != ts {
		t.Fatalf("recovery time = %v, want %d", got, ts)
	}
	plain := enc(`{}`) + "." + enc(`{"amr":[{"method":"oauth","timestamp":5}]}`) + ".sig"
	if !recoveryAuthTime(plain).IsZero() || !recoveryAuthTime("garbage").IsZero() {
		t.Fatal("non-recovery tokens must yield zero")
	}
}

// Stub Supabase: token "id|email|recoveredUnix" (recoveredUnix 0 = not a recovery session).
func stubSupabase(env *testEnv) {
	env.api.SetSupabaseAuth("https://stub.supabase.co", "anon")
	env.api.verifySupabaseToken = func(_ context.Context, token string) (supabaseUser, error) {
		p := strings.Split(token, "|")
		if len(p) != 3 {
			return supabaseUser{}, fmt.Errorf("bad stub token")
		}
		var rec int64
		fmt.Sscan(p[2], &rec)
		u := supabaseUser{ID: p[0], Email: p[1], EmailConfirmed: true}
		if rec > 0 {
			u.RecoveredAt = time.Unix(rec, 0)
		}
		return u, nil
	}
}

func TestPasswordResetAndEmailChange(t *testing.T) {
	env := newTestEnv(t)
	stubSupabase(env)
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	sfx := uniqueUsername("")
	uid, email := "u"+sfx, "r"+sfx+"@x.com"
	name := "reset" + strings.ReplaceAll(sfx, "-", "")

	// An account linked to Supabase user uid, without an account password, so
	// no registration lock applies.
	env.doJSON("POST", "/v1/accounts", "", "", map[string]string{
		"username": name, "password": "device-pw-1",
		"supabaseAccessToken": uid + "|" + email + "|0",
	}, http.StatusCreated, nil)

	now := time.Now().Unix()
	body := func(tok string) map[string]string {
		return map[string]string{"accessToken": tok, "accountPassword": "new-account-pw", "password": "device-pw-2"}
	}
	// A normal (non-recovery) session can't reset the password.
	env.doJSON("POST", "/v1/accounts/password-reset", "", "", body(uid+"|"+email+"|0"), http.StatusForbidden, nil)
	// Nor can a stale recovery session.
	stale := now - int64((passwordResetWindow + time.Minute).Seconds())
	env.doJSON("POST", "/v1/accounts/password-reset", "", "", body(fmt.Sprintf("%s|%s|%d", uid, email, stale)), http.StatusForbidden, nil)
	// A fresh recovery session for an email with no account: 404.
	env.doJSON("POST", "/v1/accounts/password-reset", "", "", body(fmt.Sprintf("nobody|n%s@x.com|%d", sfx, now)), http.StatusNotFound, nil)

	// Registration lock: an account with an account password, used this week,
	// can't be reset from the inbox alone.
	lockedUID, lockedEmail := "l"+sfx, "l"+sfx+"@x.com"
	env.doJSON("POST", "/v1/accounts", "", "", map[string]string{
		"username": "locked" + strings.ReplaceAll(sfx, "-", ""), "password": "device-pw-1", "accountPassword": "old-account-pw",
		"supabaseAccessToken": lockedUID + "|" + lockedEmail + "|0",
	}, http.StatusCreated, nil)
	var lockedErr struct {
		Error string `json:"error"`
	}
	env.doJSON("POST", "/v1/accounts/password-reset", "", "", body(fmt.Sprintf("%s|%s|%d", lockedUID, lockedEmail, now)), http.StatusLocked, &lockedErr)
	if !strings.Contains(lockedErr.Error, "7 days") {
		t.Fatalf("locked reset message = %q", lockedErr.Error)
	}

	// A fresh recovery session resets it and provisions a new device.
	var reset struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
	}
	env.doJSON("POST", "/v1/accounts/password-reset", "", "", body(fmt.Sprintf("%s|%s|%d", uid, email, now)), http.StatusCreated, &reset)
	if reset.DeviceID != 2 {
		t.Fatalf("reset device = %+v, want device 2", reset)
	}
	if devs, _ := env.api.store.Devices(reset.AccountID); len(devs) != 1 {
		t.Fatalf("old device not replaced: %+v", devs)
	}
	// Recovery takes the new password.
	env.doJSON("POST", "/v1/accounts/recover", "", "", map[string]string{"email": email, "accountPassword": "old-account-pw"}, http.StatusUnauthorized, nil)

	// Email change: signed in as the new device.
	c := &client{env: env, username: name, accountID: reset.AccountID, deviceID: reset.DeviceID, password: "device-pw-2"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()
	newEmail := "n" + sfx + "@x.com"
	// Another Supabase user's session is refused.
	env.doJSON("PUT", "/v1/accounts/me/email", c.authUser(), c.password, map[string]string{"accessToken": "someone-else|" + newEmail + "|0"}, http.StatusForbidden, nil)
	// The account's own user, with the new confirmed email, succeeds.
	env.doJSON("PUT", "/v1/accounts/me/email", c.authUser(), c.password, map[string]string{"accessToken": uid + "|" + newEmail + "|0"}, http.StatusNoContent, nil)
	// Recovery follows the new email, not the old one.
	env.doJSON("POST", "/v1/accounts/recover", "", "", map[string]string{"email": email, "accountPassword": "new-account-pw"}, http.StatusUnauthorized, nil)
	env.doJSON("POST", "/v1/accounts/recover", "", "", map[string]string{"email": newEmail, "accountPassword": "new-account-pw"}, http.StatusCreated, nil)
}
