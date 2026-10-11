package api

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/protocol/webauthncbor"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/relayapp/relay-server/internal/store"
)

// softAuthenticator is a minimal ES256 platform authenticator producing what
// an iOS passkey would: "none" attestation, UV set, backup-eligible, counter 0.
type softAuthenticator struct {
	t      *testing.T
	key    *ecdsa.PrivateKey
	credID []byte
	handle []byte
	rpID   string
	origin string
	flags  byte
}

const (
	flagUP = 0x01
	flagUV = 0x04
	flagBE = 0x08
	flagBS = 0x10
	flagAT = 0x40
)

func newSoftAuthenticator(t *testing.T) *softAuthenticator {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	id := make([]byte, 16)
	rand.Read(id)
	return &softAuthenticator{t: t, key: key, credID: id, rpID: DefaultPasskeyRPID,
		origin: DefaultPasskeyOrigin, flags: flagUP | flagUV | flagBE | flagBS}
}

func (a *softAuthenticator) clientData(typ, challenge string) []byte {
	b, _ := json.Marshal(map[string]any{"type": typ, "challenge": challenge, "origin": a.origin, "crossOrigin": false})
	return b
}

func (a *softAuthenticator) authData(extra byte, attested []byte) []byte {
	h := sha256.Sum256([]byte(a.rpID))
	out := append(h[:], a.flags|extra, 0, 0, 0, 0)
	return append(out, attested...)
}

// register returns clientDataJSON and attestationObject for challenge.
func (a *softAuthenticator) register(challenge string, userHandle []byte) (clientData, attObj []byte) {
	a.t.Helper()
	a.handle = userHandle
	x, y := a.key.PublicKey.X.FillBytes(make([]byte, 32)), a.key.PublicKey.Y.FillBytes(make([]byte, 32))
	cose, err := webauthncbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: x, -3: y})
	if err != nil {
		a.t.Fatal(err)
	}
	att := make([]byte, 16) // zero AAGUID
	att = binary.BigEndian.AppendUint16(att, uint16(len(a.credID)))
	att = append(att, a.credID...)
	att = append(att, cose...)
	attObj, err = webauthncbor.Marshal(map[string]any{"fmt": "none", "attStmt": map[string]any{}, "authData": a.authData(flagAT, att)})
	if err != nil {
		a.t.Fatal(err)
	}
	return a.clientData("webauthn.create", challenge), attObj
}

// assert returns clientDataJSON, authenticatorData and signature for challenge.
func (a *softAuthenticator) assert(challenge string) (clientData, authData, sig []byte) {
	a.t.Helper()
	clientData = a.clientData("webauthn.get", challenge)
	authData = a.authData(0, nil)
	h := sha256.Sum256(clientData)
	digest := sha256.Sum256(append(append([]byte{}, authData...), h[:]...))
	sig, err := ecdsa.SignASN1(rand.Reader, a.key, digest[:])
	if err != nil {
		a.t.Fatal(err)
	}
	return clientData, authData, sig
}

// TestPasskeyCeremonyVerification runs both ceremonies through the same
// request reconstruction and go-webauthn calls the handlers use. No database.
func TestPasskeyCeremonyVerification(t *testing.T) {
	s := New(nil, nil, nil, "", "")
	handle := make([]byte, 32)
	rand.Read(handle)
	user := &passkeyUser{handle: handle, name: "alice"}

	register := func(a *softAuthenticator) (*webauthn.Credential, error) {
		creation, sd, err := s.webauthn.BeginRegistration(user,
			webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
				ResidentKey: protocol.ResidentKeyRequirementRequired, UserVerification: protocol.VerificationRequired}),
			webauthn.WithConveyancePreference(protocol.PreferNoAttestation))
		if err != nil {
			t.Fatal(err)
		}
		cd, ao := a.register(creation.Response.Challenge.String(), handle)
		parsed, err := parseAttestation(a.credID, cd, ao)
		if err != nil {
			return nil, err
		}
		return s.webauthn.CreateCredential(user, *sd, parsed)
	}
	login := func(a *softAuthenticator, cred webauthn.Credential, mutate func(sig []byte)) (*webauthn.Credential, error) {
		assertion, sd, err := s.webauthn.BeginDiscoverableLogin(webauthn.WithUserVerification(protocol.VerificationRequired))
		if err != nil {
			t.Fatal(err)
		}
		cd, ad, sig := a.assert(assertion.Response.Challenge.String())
		if mutate != nil {
			mutate(sig)
		}
		parsed, err := parseAssertion(a.credID, cd, ad, sig, a.handle)
		if err != nil {
			return nil, err
		}
		return s.webauthn.ValidateDiscoverableLogin(func(rawID, uh []byte) (webauthn.User, error) {
			if !bytes.Equal(uh, handle) {
				return nil, store.ErrNotFound
			}
			return &passkeyUser{handle: handle, name: "alice", creds: []webauthn.Credential{cred}}, nil
		}, *sd, parsed)
	}

	a := newSoftAuthenticator(t)
	cred, err := register(a)
	if err != nil {
		t.Fatalf("registration: %v", err)
	}
	if !bytes.Equal(cred.ID, a.credID) || !cred.Flags.UserVerified {
		t.Fatalf("credential: id match %v, uv %v", bytes.Equal(cred.ID, a.credID), cred.Flags.UserVerified)
	}
	// The stored JSON must round-trip into a usable credential.
	raw, _ := json.Marshal(cred)
	var stored webauthn.Credential
	if err := json.Unmarshal(raw, &stored); err != nil {
		t.Fatal(err)
	}
	if got, err := login(a, stored, nil); err != nil || got.Authenticator.CloneWarning {
		t.Fatalf("login: %v", err)
	}
	if _, err := login(a, stored, func(sig []byte) { sig[len(sig)-1] ^= 1 }); err == nil {
		t.Fatal("tampered signature accepted")
	}

	noUV := newSoftAuthenticator(t)
	noUV.flags = flagUP
	if _, err := register(noUV); err == nil {
		t.Fatal("registration without user verification accepted")
	}
	wrongOrigin := newSoftAuthenticator(t)
	wrongOrigin.origin = "https://evil.example"
	if _, err := register(wrongOrigin); err == nil {
		t.Fatal("registration from another origin accepted")
	}
	wrongRP := newSoftAuthenticator(t)
	wrongRP.rpID = "evil.example"
	if _, err := register(wrongRP); err == nil {
		t.Fatal("registration for another RP ID accepted")
	}

	// Sign-up: a fresh handle and the stored session's username, as
	// handlePasskeySignup verifies them.
	signupHandle := make([]byte, 32)
	rand.Read(signupHandle)
	signup := func(a *softAuthenticator) (*webauthn.Credential, error) {
		creation, sd, err := s.beginPasskeyRegistration(&passkeyUser{handle: signupHandle, name: "newbie"}, nil)
		if err != nil {
			t.Fatal(err)
		}
		if creation.Response.AuthenticatorSelection.ResidentKey != protocol.ResidentKeyRequirementRequired ||
			creation.Response.AuthenticatorSelection.UserVerification != protocol.VerificationRequired ||
			creation.Response.Attestation != protocol.PreferNoAttestation {
			t.Fatalf("sign-up options: %+v", creation.Response)
		}
		if !s.passkeySignup.putNamed("sid", *sd, "newbie") {
			t.Fatal("put failed")
		}
		sess, ok := s.passkeySignup.takeNamed("sid")
		if !ok || sess.username != "newbie" || !bytes.Equal(sess.UserID, signupHandle) {
			t.Fatalf("sign-up session: %+v %v", sess, ok)
		}
		cd, ao := a.register(creation.Response.Challenge.String(), signupHandle)
		parsed, err := parseAttestation(a.credID, cd, ao)
		if err != nil {
			return nil, err
		}
		return s.webauthn.CreateCredential(&passkeyUser{handle: sess.UserID, name: sess.username}, sess.SessionData, parsed)
	}
	su := newSoftAuthenticator(t)
	suCred, err := signup(su)
	if err != nil || !bytes.Equal(suCred.ID, su.credID) || !suCred.Flags.UserVerified {
		t.Fatalf("sign-up registration: %v", err)
	}
	suNoUV := newSoftAuthenticator(t)
	suNoUV.flags = flagUP
	if _, err := signup(suNoUV); err == nil {
		t.Fatal("sign-up without user verification accepted")
	}

	// Email removal: a non-discoverable assertion restricted to the account's
	// own credentials, as handleRemoveEmail verifies it.
	owner := &passkeyUser{handle: handle, name: "alice", creds: []webauthn.Credential{stored}}
	removal := func(a *softAuthenticator, u *passkeyUser, mutate func(sig []byte)) (*webauthn.Credential, error) {
		assertion, sd, err := s.webauthn.BeginLogin(owner, webauthn.WithUserVerification(protocol.VerificationRequired))
		if err != nil {
			t.Fatal(err)
		}
		if len(assertion.Response.AllowedCredentials) != 1 || !bytes.Equal(assertion.Response.AllowedCredentials[0].CredentialID, owner.creds[0].ID) {
			t.Fatalf("allowCredentials: %+v", assertion.Response.AllowedCredentials)
		}
		cd, ad, sig := a.assert(assertion.Response.Challenge.String())
		if mutate != nil {
			mutate(sig)
		}
		parsed, err := parseAssertion(a.credID, cd, ad, sig, a.handle)
		if err != nil {
			return nil, err
		}
		return s.webauthn.ValidateLogin(u, *sd, parsed)
	}
	if got, err := removal(a, owner, nil); err != nil || got.Authenticator.CloneWarning {
		t.Fatalf("removal assertion: %v", err)
	}
	if _, err := removal(a, owner, func(sig []byte) { sig[len(sig)-1] ^= 1 }); err == nil {
		t.Fatal("removal: tampered signature accepted")
	}
	// Another account's passkey (su) can't authorise alice's removal, even
	// presented as alice's.
	su.handle = handle
	if _, err := removal(su, owner, nil); err == nil {
		t.Fatal("removal: foreign credential accepted")
	}
	// A session begun for alice doesn't verify against another user.
	if _, err := removal(a, &passkeyUser{handle: signupHandle, creds: []webauthn.Credential{stored}}, nil); err == nil {
		t.Fatal("removal: session accepted for another user")
	}
	noUVLogin := *a
	noUVLogin.flags = flagUP | flagBE | flagBS
	if _, err := removal(&noUVLogin, owner, nil); err == nil {
		t.Fatal("removal: assertion without user verification accepted")
	}
}

// TestPasskeyRequestValidation covers the checks that run before any store
// access. No database.
func TestPasskeyRequestValidation(t *testing.T) {
	for _, l := range allLimiters {
		l.reset()
	}
	s := New(nil, nil, nil, "", "")
	dev := &store.Device{AccountID: "acct"}
	call := func(h func(http.ResponseWriter, *http.Request), body string) (int, string) {
		req := httptest.NewRequest("POST", "/", strings.NewReader(body))
		req.RemoteAddr = "198.51.100.40:1"
		rec := httptest.NewRecorder()
		h(rec, req)
		return rec.Code, rec.Body.String()
	}
	register := func(w http.ResponseWriter, r *http.Request) { s.handlePasskeyRegister(w, r, dev) }
	b := b64URL([]byte("x"))

	cases := []struct {
		name string
		h    func(http.ResponseWriter, *http.Request)
		body string
		want int
	}{
		{"register: bad json", register, `{`, 400},
		{"register: trailing data", register, `{} {}`, 400},
		{"register: missing fields", register, `{"credentialId":"` + b + `"}`, 400},
		{"register: bad base64", register, `{"credentialId":"!!","clientDataJSON":"` + b + `","attestationObject":"` + b + `"}`, 400},
		{"register: long name", register, `{"credentialId":"` + b + `","clientDataJSON":"` + b + `","attestationObject":"` + b + `","name":"` + strings.Repeat("é", 65) + `"}`, 400},
		{"register: no session", register, `{"credentialId":"` + b + `","clientDataJSON":"` + b + `","attestationObject":"` + b + `","name":"` + strings.Repeat("é", 64) + `"}`, 400},
		{"login: short password", s.handlePasskeyLogin, `{"sessionId":"s","credentialId":"` + b + `","clientDataJSON":"` + b + `","authenticatorData":"` + b + `","signature":"` + b + `","userHandle":"` + b + `","password":"short"}`, 400},
		{"login: missing userHandle", s.handlePasskeyLogin, `{"sessionId":"s","credentialId":"` + b + `","clientDataJSON":"` + b + `","authenticatorData":"` + b + `","signature":"` + b + `","password":"long-enough"}`, 400},
		{"login: unknown session", s.handlePasskeyLogin, `{"sessionId":"s","credentialId":"` + b + `","clientDataJSON":"` + b + `","authenticatorData":"` + b + `","signature":"` + b + `","userHandle":"` + b + `","password":"long-enough"}`, 401},
	}
	for _, c := range cases {
		if got, body := call(c.h, c.body); got != c.want {
			t.Errorf("%s: got %d %s, want %d", c.name, got, body, c.want)
		}
	}

	// Login options need no store; the session is single use.
	code, body := call(s.handlePasskeyLoginOptions, "")
	var opts struct {
		Challenge string `json:"challenge"`
		SessionID string `json:"sessionId"`
	}
	if code != 200 || json.Unmarshal([]byte(body), &opts) != nil || opts.Challenge == "" || opts.SessionID == "" {
		t.Fatalf("login options: %d %s", code, body)
	}
	if _, ok := s.passkeyLogin.take(opts.SessionID); !ok {
		t.Fatal("login session not stored")
	}
	if _, ok := s.passkeyLogin.take(opts.SessionID); ok {
		t.Fatal("login session reusable")
	}

	// Local testing override from relayd's flags.
	if err := s.SetPasskeyRP("localhost", []string{"http://localhost:8089"}); err != nil {
		t.Fatalf("localhost RP: %v", err)
	}
	if err := s.SetPasskeyRP("relaymsg.app", nil); err == nil {
		t.Fatal("RP config without origins accepted")
	}
}

func TestPasskeySessions(t *testing.T) {
	p := newPasskeySessions()
	if !p.put("a", webauthn.SessionData{Challenge: "c"}) {
		t.Fatal("put failed")
	}
	if sd, ok := p.take("a"); !ok || sd.Challenge != "c" || sd.Expires.IsZero() {
		t.Fatalf("take: %+v %v", sd, ok)
	}
	p.put("old", webauthn.SessionData{Expires: time.Now().Add(-time.Second)})
	if _, ok := p.take("old"); ok {
		t.Fatal("expired session returned")
	}
	for i := 0; i < maxPasskeySessions; i++ {
		p.m["live-"+strconv.Itoa(i)] = passkeySession{SessionData: webauthn.SessionData{Expires: time.Now().Add(time.Minute)}}
	}
	if p.put("overflow", webauthn.SessionData{}) {
		t.Fatal("put beyond the cap succeeded")
	}
	for k := range p.m {
		p.m[k] = passkeySession{SessionData: webauthn.SessionData{Expires: time.Now().Add(-time.Second)}}
	}
	if !p.put("overflow", webauthn.SessionData{}) || len(p.m) != 1 {
		t.Fatalf("expired sessions not pruned at the cap: %d left", len(p.m))
	}
}

// TestPasskeyEndToEnd drives every endpoint against Postgres.
func TestPasskeyEndToEnd(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("pk-alice", "password-alice")
	// A registration lock must not block a passkey sign-in.
	env.doJSON("PUT", "/v1/accounts/me/account-password", alice.authUser(), alice.password,
		map[string]string{"accountPassword": "account-pw-123"}, http.StatusNoContent, nil)

	var opts struct {
		Challenge  string   `json:"challenge"`
		UserID     string   `json:"userId"`
		UserName   string   `json:"userName"`
		ExcludeIDs []string `json:"excludeCredentialIds"`
		SessionID  string   `json:"sessionId"`
	}
	env.doJSON("POST", "/v1/passkeys/register/options", alice.authUser(), alice.password, nil, http.StatusOK, &opts)
	handle, err := decodeB64URL(opts.UserID)
	if err != nil || len(handle) != 32 || opts.UserName != alice.username || len(opts.ExcludeIDs) != 0 {
		t.Fatalf("register options: %+v", opts)
	}
	a := newSoftAuthenticator(t)
	cd, ao := a.register(opts.Challenge, handle)
	regBody := map[string]string{"credentialId": b64URL(a.credID), "clientDataJSON": b64URL(cd),
		"attestationObject": b64URL(ao), "name": "iPhone"}
	var created struct {
		ID string `json:"id"`
	}
	env.doJSON("POST", "/v1/passkeys/register", alice.authUser(), alice.password, regBody, http.StatusCreated, &created)
	if created.ID != b64URL(a.credID) {
		t.Fatalf("register: id %q", created.ID)
	}
	// The session was consumed.
	env.doJSON("POST", "/v1/passkeys/register", alice.authUser(), alice.password, regBody, http.StatusBadRequest, nil)
	env.doJSON("POST", "/v1/passkeys/register/options", alice.authUser(), alice.password, nil, http.StatusOK, &opts)
	if len(opts.ExcludeIDs) != 1 || opts.ExcludeIDs[0] != created.ID {
		t.Fatalf("exclude list: %v", opts.ExcludeIDs)
	}

	var list struct {
		Passkeys []struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			CreatedAt int64  `json:"createdAt"`
		} `json:"passkeys"`
	}
	env.doJSON("GET", "/v1/passkeys", alice.authUser(), alice.password, nil, http.StatusOK, &list)
	if len(list.Passkeys) != 1 || list.Passkeys[0].Name != "iPhone" || list.Passkeys[0].CreatedAt%86400000 != 0 {
		t.Fatalf("list: %+v", list)
	}

	signIn := func(a *softAuthenticator, want int) map[string]any {
		t.Helper()
		env.doJSON("POST", "/v1/passkeys/login/options", "", "", nil, http.StatusOK, &opts)
		cd, ad, sig := a.assert(opts.Challenge)
		var out map[string]any
		env.doJSON("POST", "/v1/passkeys/login", "", "", map[string]string{
			"sessionId": opts.SessionID, "credentialId": b64URL(a.credID), "clientDataJSON": b64URL(cd),
			"authenticatorData": b64URL(ad), "signature": b64URL(sig), "userHandle": b64URL(a.handle),
			"password": "new-device-pw",
		}, want, &out)
		return out
	}
	out := signIn(a, http.StatusOK)
	if out["accountId"] != alice.accountID || out["username"] != alice.username || out["created"] != false || out["mailboxId"] == "" {
		t.Fatalf("login: %+v", out)
	}
	// The old device was replaced.
	env.doJSON("GET", "/v1/keys/count", alice.authUser(), alice.password, nil, http.StatusUnauthorized, nil)

	// An unregistered credential claiming alice's handle fails generically.
	stranger := newSoftAuthenticator(t)
	stranger.handle = handle
	signIn(stranger, http.StatusUnauthorized)

	// Delete: only the owner's passkey, then it no longer signs in.
	bob := env.register("pk-bob", "password-bob")
	env.doJSON("DELETE", "/v1/passkeys/"+created.ID, bob.authUser(), bob.password, nil, http.StatusNotFound, nil)
	if err := env.api.store.DeletePasskey(alice.accountID, a.credID); err != nil {
		t.Fatal(err)
	}
	signIn(a, http.StatusUnauthorized)

	// Demo accounts can't register.
	demo := env.register("pk-demo", "password-demo")
	if err := env.api.store.SetDemoAccount(demo.accountID, true); err != nil {
		t.Fatal(err)
	}
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()
	env.doJSON("POST", "/v1/passkeys/register/options", demo.authUser(), demo.password, nil, http.StatusForbidden, nil)

	// Account deletion takes its passkeys with it.
	env.doJSON("POST", "/v1/passkeys/register/options", bob.authUser(), bob.password, nil, http.StatusOK, &opts)
	bh, _ := decodeB64URL(opts.UserID)
	bk := newSoftAuthenticator(t)
	cd, ao = bk.register(opts.Challenge, bh)
	env.doJSON("POST", "/v1/passkeys/register", bob.authUser(), bob.password, map[string]string{
		"credentialId": b64URL(bk.credID), "clientDataJSON": b64URL(cd), "attestationObject": b64URL(ao),
	}, http.StatusCreated, nil)
	env.doJSON("DELETE", "/v1/passkeys/"+b64URL([]byte("nope")), bob.authUser(), bob.password, nil, http.StatusNotFound, nil)
	env.doJSON("DELETE", "/v1/accounts/me", bob.authUser(), bob.password, nil, http.StatusNoContent, nil)
	if pk, err := env.api.store.ListPasskeys(bob.accountID); err != nil || len(pk) != 0 {
		t.Fatalf("passkeys survived account deletion: %d %v", len(pk), err)
	}
}
