package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/store"
)

func TestRecoveryKeyNormalization(t *testing.T) {
	if got := normalizeRecoveryKey("abcd-efgh ijkl"); got != "ABCDEFGHIJKL" {
		t.Fatalf("normalize: %q", got)
	}
	for in, want := range map[string]string{
		"":                       "",
		"a1b2-C3D4\n e5f6\t":     "A1B2C3D4E5F6",
		"ÄBC-ıx_9":               "BCX9", // non-ASCII is dropped, never folded
		"  ABCD EFGH IJKL MNOP ": "ABCDEFGHIJKLMNOP",
	} {
		if got := normalizeRecoveryKey(in); got != want {
			t.Errorf("normalize(%q) = %q, want %q", in, got, want)
		}
	}
	h := recoveryKeyHash("ABCDEFGHIJKL")
	want := sha256.Sum256([]byte("relay-recovery-key-v1|ABCDEFGHIJKL"))
	if hex.EncodeToString(h) != hex.EncodeToString(want[:]) {
		t.Fatal("hash construction changed")
	}
	const vector = "24afe96099424bd806835c7b825f3068652949720dcbc4dfec07a6a3d3d82576"
	t.Logf(`SHA-256("relay-recovery-key-v1|ABCDEFGHIJKL") = %x`, h)
	if hex.EncodeToString(h) != vector {
		t.Fatalf("test vector: got %x, want %s", h, vector)
	}
}

// TestSignInMethodRequestValidation covers the checks on the passkey sign-up,
// email removal and recovery key endpoints that run before any store access.
// No database.
func TestSignInMethodRequestValidation(t *testing.T) {
	for _, l := range allLimiters {
		l.reset()
	}
	s := New(nil, nil, nil, "", "")
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{
		"acct": {demo: false, at: time.Now()},
		"demo": {demo: true, at: time.Now()},
	}
	demoFlags.mu.Unlock()
	t.Cleanup(func() {
		demoFlags.mu.Lock()
		demoFlags.entries = map[string]demoCacheEntry{}
		demoFlags.mu.Unlock()
	})
	call := func(h func(http.ResponseWriter, *http.Request), method, body string) (int, string) {
		req := httptest.NewRequest(method, "/", strings.NewReader(body))
		req.RemoteAddr = "198.51.100.41:1"
		rec := httptest.NewRecorder()
		h(rec, req)
		return rec.Code, rec.Body.String()
	}
	as := func(accountID string, h func(http.ResponseWriter, *http.Request, *store.Device)) func(http.ResponseWriter, *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) { h(w, r, &store.Device{AccountID: accountID}) }
	}
	b := b64URL([]byte("x"))
	hash32 := b64URL(make([]byte, 32))
	assertion := `"credentialId":"` + b + `","clientDataJSON":"` + b + `","authenticatorData":"` + b + `","signature":"` + b + `","userHandle":"` + b + `"`
	attestation := `"credentialId":"` + b + `","clientDataJSON":"` + b + `","attestationObject":"` + b + `"`

	cases := []struct {
		name   string
		h      func(http.ResponseWriter, *http.Request)
		method string
		body   string
		want   int
	}{
		{"signup options: bad json", s.handlePasskeySignupOptions, "POST", `{`, 400},
		{"signup options: no username", s.handlePasskeySignupOptions, "POST", `{}`, 400},
		{"signup options: bad username", s.handlePasskeySignupOptions, "POST", `{"username":"a b"}`, 400},
		{"signup options: long username", s.handlePasskeySignupOptions, "POST", `{"username":"` + strings.Repeat("a", 65) + `"}`, 400},
		{"signup: bad json", s.handlePasskeySignup, "POST", `{`, 400},
		{"signup: no session", s.handlePasskeySignup, "POST", `{` + attestation + `,"password":"long-enough"}`, 400},
		{"signup: short password", s.handlePasskeySignup, "POST", `{"sessionId":"s",` + attestation + `,"password":"short"}`, 400},
		{"signup: long password", s.handlePasskeySignup, "POST", `{"sessionId":"s",` + attestation + `,"password":"` + strings.Repeat("p", 1025) + `"}`, 400},
		{"signup: missing attestation", s.handlePasskeySignup, "POST", `{"sessionId":"s","credentialId":"` + b + `","password":"long-enough"}`, 400},
		{"signup: bad base64", s.handlePasskeySignup, "POST", `{"sessionId":"s","credentialId":"!!","clientDataJSON":"` + b + `","attestationObject":"` + b + `","password":"long-enough"}`, 400},
		{"signup: long name", s.handlePasskeySignup, "POST", `{"sessionId":"s",` + attestation + `,"password":"long-enough","name":"` + strings.Repeat("é", 65) + `"}`, 400},
		{"signup: unknown session", s.handlePasskeySignup, "POST", `{"sessionId":"s",` + attestation + `,"password":"long-enough","name":"` + strings.Repeat("é", 64) + `"}`, 401},
		{"remove options: demo", as("demo", s.handleRemoveEmailOptions), "POST", ``, 403},
		{"remove: demo", as("demo", s.handleRemoveEmail), "POST", `{` + assertion + `}`, 403},
		{"remove: bad json", as("acct", s.handleRemoveEmail), "POST", `{`, 400},
		{"remove: missing userHandle", as("acct", s.handleRemoveEmail), "POST", `{"credentialId":"` + b + `","clientDataJSON":"` + b + `","authenticatorData":"` + b + `","signature":"` + b + `"}`, 400},
		{"remove: no session", as("acct", s.handleRemoveEmail), "POST", `{` + assertion + `}`, 401},
		{"set key: demo", as("demo", s.handleSetRecoveryKey), "PUT", `{"hash":"` + hash32 + `"}`, 403},
		{"set key: bad json", as("acct", s.handleSetRecoveryKey), "PUT", `{`, 400},
		{"set key: missing", as("acct", s.handleSetRecoveryKey), "PUT", `{}`, 400},
		{"set key: 31 bytes", as("acct", s.handleSetRecoveryKey), "PUT", `{"hash":"` + b64URL(make([]byte, 31)) + `"}`, 400},
		{"set key: 33 bytes", as("acct", s.handleSetRecoveryKey), "PUT", `{"hash":"` + b64URL(make([]byte, 33)) + `"}`, 400},
		{"set key: standard base64", as("acct", s.handleSetRecoveryKey), "PUT", `{"hash":"+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+="}`, 400},
		{"key signin: bad json", s.handleRecoveryKeySignIn, "POST", `{`, 400},
		{"key signin: no key", s.handleRecoveryKeySignIn, "POST", `{"password":"long-enough"}`, 400},
		{"key signin: long key", s.handleRecoveryKeySignIn, "POST", `{"key":"` + strings.Repeat("A", 129) + `","password":"long-enough"}`, 400},
		{"key signin: short password", s.handleRecoveryKeySignIn, "POST", `{"key":"ABCD-EFGH-IJKL-MNOP-QRST","password":"short"}`, 400},
		{"key signin: too short once normalized", s.handleRecoveryKeySignIn, "POST", `{"key":"ABCD----EFGH----IJKL----MNOP----QRS","password":"long-enough"}`, 401},
		{"key signin: too long once normalized", s.handleRecoveryKeySignIn, "POST", `{"key":"` + strings.Repeat("A", 41) + `","password":"long-enough"}`, 401},
	}
	for _, c := range cases {
		if got, body := call(c.h, c.method, c.body); got != c.want {
			t.Errorf("%s: got %d %s, want %d", c.name, got, body, c.want)
		}
	}

	// 10/IP/hour, then 429.
	for range 10 {
		call(s.handleRecoveryKeySignIn, "POST", `{}`)
	}
	if got, _ := call(s.handleRecoveryKeySignIn, "POST", `{}`); got != http.StatusTooManyRequests {
		t.Fatalf("recovery key sign-in past the per-IP limit: %d", got)
	}
}

// TestSignInMethodsEndToEnd drives passkey sign-up, sign-in methods, email
// removal and the recovery key against Postgres.
func TestSignInMethodsEndToEnd(t *testing.T) {
	env := newTestEnv(t)
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()

	// Passkey sign-up, no email.
	username := uniqueUsername("pk-new")
	var opts struct {
		SessionID string `json:"sessionId"`
		Challenge string `json:"challenge"`
		UserID    string `json:"userId"`
		UserName  string `json:"userName"`
	}
	env.doJSON("POST", "/v1/passkeys/signup/options", "", "", map[string]string{"username": username}, http.StatusOK, &opts)
	handle, err := decodeB64URL(opts.UserID)
	if err != nil || len(handle) != 32 || opts.UserName != username || opts.SessionID == "" {
		t.Fatalf("signup options: %+v", opts)
	}
	a := newSoftAuthenticator(t)
	cd, ao := a.register(opts.Challenge, handle)
	body := map[string]string{"sessionId": opts.SessionID, "credentialId": b64URL(a.credID), "clientDataJSON": b64URL(cd),
		"attestationObject": b64URL(ao), "password": "device-pw-1", "name": "iPhone"}
	var created struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
		Username  string `json:"username"`
		MailboxID string `json:"mailboxId"`
		Created   bool   `json:"created"`
	}
	env.doJSON("POST", "/v1/passkeys/signup", "", "", body, http.StatusCreated, &created)
	if created.AccountID == "" || created.DeviceID != 1 || created.Username != username || created.MailboxID == "" || !created.Created {
		t.Fatalf("signup: %+v", created)
	}
	env.doJSON("POST", "/v1/passkeys/signup", "", "", body, http.StatusUnauthorized, nil) // session consumed
	env.doJSON("POST", "/v1/passkeys/signup/options", "", "", map[string]string{"username": strings.ToUpper(username)}, http.StatusConflict, nil)

	// A second sign-up for a name taken meanwhile loses the race with 409.
	race := uniqueUsername("pk-race")
	env.doJSON("POST", "/v1/passkeys/signup/options", "", "", map[string]string{"username": race}, http.StatusOK, &opts)
	env.registerAs(race, "password-race")
	rh, _ := decodeB64URL(opts.UserID)
	ra := newSoftAuthenticator(t)
	cd, ao = ra.register(opts.Challenge, rh)
	env.doJSON("POST", "/v1/passkeys/signup", "", "", map[string]string{"sessionId": opts.SessionID, "credentialId": b64URL(ra.credID),
		"clientDataJSON": b64URL(cd), "attestationObject": b64URL(ao), "password": "device-pw-1"}, http.StatusConflict, nil)

	alice := &client{env: env, username: username, accountID: created.AccountID, mailboxID: created.MailboxID, deviceID: 1, password: "device-pw-1"}
	env.clients[alice.authUser()] = alice
	alice.uploadDeviceAuthKey()

	type methods struct {
		Email           bool `json:"email"`
		Passkeys        int  `json:"passkeys"`
		AccountPassword bool `json:"accountPassword"`
		RecoveryKey     bool `json:"recoveryKey"`
	}
	var m methods
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", alice.authUser(), alice.password, nil, http.StatusOK, &m)
	if m != (methods{Passkeys: 1}) {
		t.Fatalf("sign-in methods: %+v", m)
	}

	// The signed-up passkey signs in.
	var login struct {
		Challenge string `json:"challenge"`
		SessionID string `json:"sessionId"`
	}
	env.doJSON("POST", "/v1/passkeys/login/options", "", "", nil, http.StatusOK, &login)
	cd, ad, sig := a.assert(login.Challenge)
	var out map[string]any
	env.doJSON("POST", "/v1/passkeys/login", "", "", map[string]string{"sessionId": login.SessionID, "credentialId": b64URL(a.credID),
		"clientDataJSON": b64URL(cd), "authenticatorData": b64URL(ad), "signature": b64URL(sig), "userHandle": b64URL(a.handle),
		"password": "device-pw-2"}, http.StatusOK, &out)
	if out["accountId"] != alice.accountID {
		t.Fatalf("passkey login: %+v", out)
	}
	alice = &client{env: env, username: username, accountID: created.AccountID, deviceID: uint32(out["deviceId"].(float64)), password: "device-pw-2"}
	env.clients[alice.authUser()] = alice
	alice.uploadDeviceAuthKey()

	// Recovery key: set, sign in, replace, delete.
	key := "abcd-efgh-ijkl-mnop-qrst-uvwx"
	h := recoveryKeyHash(normalizeRecoveryKey(key))
	env.doJSON("PUT", "/v1/accounts/me/recovery-key", alice.authUser(), alice.password, map[string]string{"hash": b64URL(h)}, http.StatusNoContent, nil)
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", alice.authUser(), alice.password, nil, http.StatusOK, &m)
	if !m.RecoveryKey {
		t.Fatalf("sign-in methods: %+v", m)
	}
	env.doJSON("POST", "/v1/accounts/recovery-key/signin", "", "", map[string]string{"key": "ABCDEFGHIJKLMNOPQRSTUVWY", "password": "device-pw-3"}, http.StatusUnauthorized, nil)
	env.doJSON("POST", "/v1/accounts/recovery-key/signin", "", "", map[string]string{"key": "ABCD EFGH IJKL MNOP QRST UVWX", "password": "device-pw-3"}, http.StatusOK, &out)
	if out["accountId"] != alice.accountID || out["username"] != username || out["created"] != false || out["mailboxId"] == "" {
		t.Fatalf("recovery key sign-in: %+v", out)
	}
	env.doJSON("GET", "/v1/keys/count", alice.authUser(), alice.password, nil, http.StatusUnauthorized, nil) // replaced
	alice = &client{env: env, username: username, accountID: created.AccountID, deviceID: uint32(out["deviceId"].(float64)), password: "device-pw-3"}
	env.clients[alice.authUser()] = alice
	alice.uploadDeviceAuthKey()
	env.doJSON("DELETE", "/v1/accounts/me/recovery-key", alice.authUser(), alice.password, nil, http.StatusNoContent, nil)
	env.doJSON("POST", "/v1/accounts/recovery-key/signin", "", "", map[string]string{"key": key, "password": "device-pw-4"}, http.StatusUnauthorized, nil)

	// Email removal on an account with a verified email and Supabase link.
	acct, _, err := env.api.store.CreateAccount(uniqueUsername("rm-email"), []byte(uniqueUsername("tok")), uniqueUsername("supa"), "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	bob := &client{env: env, accountID: acct, deviceID: 1, password: "device-pw-1"}
	env.clients[bob.authUser()] = bob
	bob.uploadDeviceAuthKey()
	env.doJSON("POST", "/v1/accounts/me/email/remove/options", bob.authUser(), bob.password, nil, http.StatusConflict, nil)

	var reg struct {
		Challenge string `json:"challenge"`
		UserID    string `json:"userId"`
	}
	env.doJSON("POST", "/v1/passkeys/register/options", bob.authUser(), bob.password, nil, http.StatusOK, &reg)
	bh, _ := decodeB64URL(reg.UserID)
	bk := newSoftAuthenticator(t)
	cd, ao = bk.register(reg.Challenge, bh)
	env.doJSON("POST", "/v1/passkeys/register", bob.authUser(), bob.password, map[string]string{
		"credentialId": b64URL(bk.credID), "clientDataJSON": b64URL(cd), "attestationObject": b64URL(ao)}, http.StatusCreated, nil)

	removeWith := func(k *softAuthenticator, want int) {
		t.Helper()
		var ro struct {
			Challenge     string   `json:"challenge"`
			CredentialIDs []string `json:"credentialIds"`
		}
		env.doJSON("POST", "/v1/accounts/me/email/remove/options", bob.authUser(), bob.password, nil, http.StatusOK, &ro)
		if len(ro.CredentialIDs) != 1 || ro.CredentialIDs[0] != b64URL(bk.credID) {
			t.Fatalf("remove options: %+v", ro)
		}
		cd, ad, sig := k.assert(ro.Challenge)
		env.doJSON("POST", "/v1/accounts/me/email/remove", bob.authUser(), bob.password, map[string]string{
			"credentialId": b64URL(k.credID), "clientDataJSON": b64URL(cd), "authenticatorData": b64URL(ad),
			"signature": b64URL(sig), "userHandle": b64URL(k.handle)}, want, nil)
	}
	// Alice's passkey can't authorise Bob's removal.
	a.handle = bh
	removeWith(a, http.StatusUnauthorized)
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", bob.authUser(), bob.password, nil, http.StatusOK, &m)
	if !m.Email || m.Passkeys != 1 {
		t.Fatalf("before removal: %+v", m)
	}
	removeWith(bk, http.StatusNoContent)
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", bob.authUser(), bob.password, nil, http.StatusOK, &m)
	if m.Email {
		t.Fatalf("after removal: %+v", m)
	}
	if id, err := env.api.store.SupabaseUserID(acct); err != nil || id != "" {
		t.Fatalf("supabase link survived: %q %v", id, err)
	}

	// Demo accounts can't set a recovery key or remove an email.
	demo := env.register("rk-demo", "password-demo")
	if err := env.api.store.SetDemoAccount(demo.accountID, true); err != nil {
		t.Fatal(err)
	}
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()
	env.doJSON("PUT", "/v1/accounts/me/recovery-key", demo.authUser(), demo.password, map[string]string{"hash": b64URL(make([]byte, 32))}, http.StatusForbidden, nil)
	env.doJSON("POST", "/v1/accounts/me/email/remove/options", demo.authUser(), demo.password, nil, http.StatusForbidden, nil)
}
