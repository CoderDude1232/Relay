package api

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/idtoken"
	"github.com/relayapp/relay-server/internal/mail"
	"github.com/relayapp/relay-server/internal/oprf"
)

// stubMail records the codes it would have sent.
type stubMail struct {
	mu   sync.Mutex
	sent map[string]string // address → last code
	n    int
}

func (m *stubMail) SendCode(_ context.Context, to string, _ mail.Purpose, code string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent[to] = code
	m.n++
	return nil
}

func (m *stubMail) code(t *testing.T, to string) string {
	t.Helper()
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.sent[to]
	if !ok {
		t.Fatalf("no code sent to %s", to)
	}
	return c
}

func signIDToken(t *testing.T, key *rsa.PrivateKey, claims map[string]any) string {
	t.Helper()
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	signing := enc(map[string]string{"alg": "RS256", "kid": "k1"}) + "." + enc(claims)
	digest := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func identityEnv(t *testing.T) (*testEnv, *stubMail, *rsa.PrivateKey) {
	env := newTestEnv(t)
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	m := &stubMail{sent: map[string]string{}}
	env.api.SetEmailCodes(m, 1000)
	signer, _ := rsa.GenerateKey(rand.Reader, 2048)
	apple := idtoken.NewVerifier(idtoken.Apple("app.relaymsg"))
	apple.SetKeys(map[string]*rsa.PublicKey{"k1": &signer.PublicKey}, time.Now)
	env.api.SetIdentityProviders(apple, nil)
	return env, m, signer
}

type ticketResp struct {
	Token string `json:"token"`
	Email string `json:"email"`
}

type signInResp struct {
	AccountID string `json:"accountId"`
	Username  string `json:"username"`
	Created   bool   `json:"created"`
}

func TestEmailCodeSignIn(t *testing.T) {
	env, m, _ := identityEnv(t)
	sfx := uniqueUsername("")
	email := "Mixed.Case" + sfx + "@Example.com"
	normalized := strings.ToLower(email)

	env.doJSON("POST", "/v1/email/code", "", "", map[string]string{"email": "not-an-address"}, http.StatusBadRequest, nil)
	env.doJSON("POST", "/v1/email/code", "", "", map[string]string{"email": email}, http.StatusNoContent, nil)
	code := m.code(t, normalized)

	// Wrong codes are counted; after five the code is gone.
	wrong := fmt.Sprintf("%06d", (mustAtoi(code)+1)%1_000_000)
	env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": email, "code": wrong}, http.StatusUnauthorized, nil)
	var ticket ticketResp
	env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": email, "code": code}, http.StatusOK, &ticket)
	if !strings.HasPrefix(ticket.Token, identityTicketPrefix) || ticket.Email != normalized {
		t.Fatalf("ticket: %+v", ticket)
	}
	// A code works once.
	env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": email, "code": code}, http.StatusUnauthorized, nil)

	// The ticket signs up (username first), then signs in again.
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{"accessToken": ticket.Token, "password": "device-pw-1"},
		http.StatusNotFound, nil)
	var first signInResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{"accessToken": ticket.Token, "username": "em" + sfx, "password": "device-pw-1"},
		http.StatusCreated, &first)

	env.doJSON("POST", "/v1/email/code", "", "", map[string]string{"email": normalized}, http.StatusNoContent, nil)
	env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": normalized, "code": m.code(t, normalized)}, http.StatusOK, &ticket)
	var again signInResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{"accessToken": ticket.Token, "password": "device-pw-2"},
		http.StatusOK, &again)
	if again.AccountID != first.AccountID || again.Created {
		t.Fatalf("second sign-in: %+v, first %+v", again, first)
	}

	// Five wrong guesses burn the code.
	env.doJSON("POST", "/v1/email/code", "", "", map[string]string{"email": normalized}, http.StatusNoContent, nil)
	good := m.code(t, normalized)
	bad := fmt.Sprintf("%06d", (mustAtoi(good)+1)%1_000_000)
	for range emailCodeAttempts {
		env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": normalized, "code": bad}, http.StatusUnauthorized, nil)
	}
	env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": normalized, "code": good}, http.StatusUnauthorized, nil)

	// Made-up tickets don't work.
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{"accessToken": identityTicketPrefix + "forged", "password": "device-pw-3"},
		http.StatusUnauthorized, nil)
}

func mustAtoi(s string) int {
	n := 0
	for _, c := range s {
		n = n*10 + int(c-'0')
	}
	return n
}

// An Apple user who signed up through Supabase lands in the same account
// when the app checks Apple's token with the relay instead.
func TestAppleIdentityMatchesSupabaseSignUp(t *testing.T) {
	env, _, signer := identityEnv(t)
	env.api.SetSupabaseAuth("https://stub.supabase.co", "anon")
	sfx := uniqueUsername("")
	appleSub := "001234." + sfx
	env.api.verifySupabaseToken = func(_ context.Context, token string) (supabaseUser, error) {
		if token != "supa-"+sfx {
			return supabaseUser{}, fmt.Errorf("bad stub token")
		}
		return supabaseUser{ID: "sb-" + sfx, Email: sfx + "@privaterelay.appleid.com", EmailConfirmed: true,
			Provider: "apple", ProviderSubject: appleSub}, nil
	}
	var viaSupabase signInResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{"accessToken": "supa-" + sfx, "username": "ap" + sfx, "password": "device-pw-1"},
		http.StatusCreated, &viaSupabase)

	nonce := "nonce-" + sfx
	now := time.Now()
	token := signIDToken(t, signer, map[string]any{"iss": "https://appleid.apple.com", "aud": "app.relaymsg",
		"sub": appleSub, "exp": now.Add(5 * time.Minute).Unix(), "iat": now.Unix(),
		"email": sfx + "@privaterelay.appleid.com", "email_verified": "true",
		"nonce": fmt.Sprintf("%x", sha256.Sum256([]byte(nonce)))})
	env.doJSON("POST", "/v1/identity/apple", "", "", map[string]string{"identityToken": token, "nonce": "wrong"}, http.StatusUnauthorized, nil)
	var ticket ticketResp
	env.doJSON("POST", "/v1/identity/apple", "", "", map[string]string{"identityToken": token, "nonce": nonce}, http.StatusOK, &ticket)
	var viaRelay signInResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{"accessToken": ticket.Token, "password": "device-pw-2"},
		http.StatusOK, &viaRelay)
	if viaRelay.AccountID != viaSupabase.AccountID {
		t.Fatalf("relay Apple sign-in found %s, Supabase account is %s", viaRelay.AccountID, viaSupabase.AccountID)
	}
	if link, err := env.api.store.SupabaseUserID(viaSupabase.AccountID); err != nil || link != "sb-"+sfx {
		t.Fatalf("supabase id kept for deletion: %q %v", link, err)
	}

	// A different Apple account doesn't.
	other := signIDToken(t, signer, map[string]any{"iss": "https://appleid.apple.com", "aud": "app.relaymsg",
		"sub": "999." + sfx, "exp": now.Add(5 * time.Minute).Unix(), "iat": now.Unix(),
		"nonce": fmt.Sprintf("%x", sha256.Sum256([]byte(nonce)))})
	env.doJSON("POST", "/v1/identity/apple", "", "", map[string]string{"identityToken": other, "nonce": nonce}, http.StatusOK, &ticket)
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{"accessToken": ticket.Token, "password": "device-pw-3"},
		http.StatusNotFound, nil) // new identity: needs a username
}

// An email-change ticket only works for the account that asked for the code.
func TestEmailChangeTicketBoundToAccount(t *testing.T) {
	env, m, _ := identityEnv(t)
	alice := env.register("chg-a", "password-a")
	bob := env.register("chg-b", "password-b")
	sfx := uniqueUsername("")
	newEmail := "new" + sfx + "@example.com"

	env.doJSON("POST", "/v1/accounts/me/email/code", alice.authUser(), alice.password,
		map[string]string{"email": newEmail}, http.StatusNoContent, nil)
	var ticket ticketResp
	env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": newEmail, "code": m.code(t, newEmail)}, http.StatusOK, &ticket)

	env.doJSON("PUT", "/v1/accounts/me/email", bob.authUser(), bob.password,
		map[string]string{"accessToken": ticket.Token}, http.StatusForbidden, nil)
	env.doJSON("PUT", "/v1/accounts/me/email", alice.authUser(), alice.password,
		map[string]string{"accessToken": ticket.Token}, http.StatusNoContent, nil)

	// A sign-in ticket for the address isn't an email change.
	env.doJSON("POST", "/v1/email/code", "", "", map[string]string{"email": newEmail}, http.StatusNoContent, nil)
	env.doJSON("POST", "/v1/email/verify", "", "", map[string]string{"email": newEmail, "code": m.code(t, newEmail)}, http.StatusOK, &ticket)
	env.doJSON("PUT", "/v1/accounts/me/email", alice.authUser(), alice.password,
		map[string]string{"accessToken": ticket.Token}, http.StatusForbidden, nil)
}
