package api

import (
	"context"
	"encoding/base64"
	"net/http"
	"strings"
	"testing"

	"github.com/relayapp/relay-server/internal/oprf"
)

// directoryHas reports whether the blinded directory holds an entry for the
// OPRF token tok (fetched the way a client would: by bucket, matched by tag).
func (c *client) directoryHas(tok []byte) bool {
	c.env.t.Helper()
	var resp struct {
		Buckets []struct {
			Entries []struct {
				Tag string `json:"tag"`
			} `json:"entries"`
		} `json:"buckets"`
	}
	c.env.doJSON("POST", "/v1/directory/buckets", c.authUser(), c.password,
		map[string]any{"buckets": []int{int(oprf.DirectoryBucket(tok))}}, http.StatusOK, &resp)
	want := base64.StdEncoding.EncodeToString(oprf.DirectoryTag(tok))
	for _, b := range resp.Buckets {
		for _, e := range b.Entries {
			if e.Tag == want {
				return true
			}
		}
	}
	return false
}

// TestEmailDiscoverabilityOptIn: a verified email is not discoverable until the
// owner opts in, and opting out removes it again; the username entry stays.
func TestEmailDiscoverabilityOptIn(t *testing.T) {
	env := newTestEnv(t)
	env.api.SetSupabaseAuth("https://stub.supabase.co", "anon")
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	env.api.verifySupabaseToken = func(_ context.Context, token string) (supabaseUser, error) {
		id, email, _ := strings.Cut(token, "|")
		return supabaseUser{ID: id, Email: email, EmailConfirmed: true}, nil
	}
	name := uniqueUsername("disc")
	email := name + "@example.com"
	var created struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
	}
	env.doJSON("POST", "/v1/accounts", "", "", map[string]string{
		"username": name, "password": "password-disc", "supabaseAccessToken": "sb-" + name + "|" + email,
	}, http.StatusCreated, &created)
	c := &client{env: env, username: name, accountID: created.AccountID, deviceID: created.DeviceID, password: "password-disc"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	emailTok, nameTok := key.Token(email), key.Token(name)
	if !c.directoryHas(nameTok) {
		t.Fatal("username not discoverable")
	}
	if c.directoryHas(emailTok) {
		t.Fatal("email discoverable without opting in")
	}
	env.doJSON("PUT", "/v1/accounts/me/discoverability", c.authUser(), c.password,
		map[string]bool{"email": true}, http.StatusNoContent, nil)
	if !c.directoryHas(emailTok) {
		t.Fatal("email not discoverable after opting in")
	}
	// A restart rebuild keeps the opt-in.
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	if !c.directoryHas(emailTok) || !c.directoryHas(nameTok) {
		t.Fatal("opt-in lost on directory rebuild")
	}
	env.doJSON("PUT", "/v1/accounts/me/discoverability", c.authUser(), c.password,
		map[string]bool{"email": false}, http.StatusNoContent, nil)
	if c.directoryHas(emailTok) {
		t.Fatal("email still discoverable after opting out")
	}
	if !c.directoryHas(nameTok) {
		t.Fatal("opting out of email removed the username entry")
	}
	// The field is required.
	env.doJSON("PUT", "/v1/accounts/me/discoverability", c.authUser(), c.password,
		map[string]any{}, http.StatusBadRequest, nil)
}
