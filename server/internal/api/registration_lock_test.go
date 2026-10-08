package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/relayapp/relay-server/internal/oprf"
)

// TestOAuthRegistrationLock: a sign-in that resolves to an existing account
// with an account password (it replaces every device) must present it.
func TestOAuthRegistrationLock(t *testing.T) {
	env := newTestEnv(t)
	recoveryLockout = newFailureLockout()
	env.api.SetSupabaseAuth("https://stub.supabase.co", "anon")
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	env.api.verifySupabaseToken = func(_ context.Context, token string) (supabaseUser, error) {
		id, email, ok := strings.Cut(token, "|")
		if !ok || id == "" {
			return supabaseUser{}, fmt.Errorf("bad stub token")
		}
		return supabaseUser{ID: id, Email: email, EmailConfirmed: true}, nil
	}
	sfx := uniqueUsername("")
	token := "lock" + sfx + "|lock" + sfx + "@x.com"

	type oauthResp struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
		Created   bool   `json:"created"`
	}
	signIn := func(accountPassword string, want int) (oauthResp, string) {
		t.Helper()
		body := map[string]string{"accessToken": token, "password": "device-pw-123"}
		if accountPassword != "" {
			body["accountPassword"] = accountPassword
		}
		raw, _ := json.Marshal(body)
		resp, err := http.Post(env.srv.URL+"/v1/accounts/oauth", "application/json", bytes.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out struct {
			oauthResp
			Error string `json:"error"`
		}
		json.NewDecoder(resp.Body).Decode(&out)
		if resp.StatusCode != want {
			t.Fatalf("sign-in (accountPassword %q): got %d %q, want %d", accountPassword, resp.StatusCode, out.Error, want)
		}
		return out.oauthResp, out.Error
	}

	// Created with an account password.
	var first oauthResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": token, "username": "lock" + sfx, "password": "device-pw-123", "accountPassword": "lock-pw-123",
	}, http.StatusCreated, &first)

	if _, msg := signIn("", http.StatusLocked); msg != "account password required" {
		t.Fatalf("missing password message %q", msg)
	}
	if _, msg := signIn("wrong-pw-123", http.StatusLocked); msg != "account password incorrect" {
		t.Fatalf("wrong password message %q", msg)
	}
	// Nothing changed: the original device is still the only one.
	if devs, err := env.api.store.Devices(first.AccountID); err != nil || len(devs) != 1 || devs[0].DeviceID != first.DeviceID {
		t.Fatalf("devices after refused sign-ins = %+v (%v)", devs, err)
	}
	if got, _ := signIn("lock-pw-123", http.StatusOK); got.AccountID != first.AccountID || got.Created {
		t.Fatalf("correct password: %+v", got)
	}

	// Wrong guesses back off: past the free allowance the account is locked
	// (429) even for the right password, until the backoff ends.
	for i := 0; i < lockoutFreeFailures+1; i++ {
		signIn("wrong-pw-123", http.StatusLocked)
	}
	signIn("lock-pw-123", http.StatusTooManyRequests)
}

// An account without an account password can set one later, which then
// guards sign-in.
func TestSetAccountPasswordEnablesLock(t *testing.T) {
	env := newTestEnv(t)
	recoveryLockout = newFailureLockout()
	env.api.SetSupabaseAuth("https://stub.supabase.co", "anon")
	env.api.verifySupabaseToken = func(_ context.Context, token string) (supabaseUser, error) {
		return supabaseUser{ID: token}, nil
	}
	sb := "set" + uniqueUsername("")
	var created struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
	}
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": sb, "username": sb, "password": "device-pw-123",
	}, http.StatusCreated, &created)
	c := &client{env: env, username: sb, accountID: created.AccountID, deviceID: created.DeviceID, password: "device-pw-123"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPassword": "short"}, http.StatusBadRequest, nil)
	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPassword": "new-lock-pw-1"}, http.StatusNoContent, nil)

	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": sb, "password": "device-pw-456",
	}, http.StatusLocked, nil)
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": sb, "password": "device-pw-456", "accountPassword": "new-lock-pw-1",
	}, http.StatusOK, nil)
}
