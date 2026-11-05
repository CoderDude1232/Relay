package idtoken

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func sign(t *testing.T, key *rsa.PrivateKey, kid string, claims map[string]any) string {
	t.Helper()
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	signing := enc(map[string]string{"alg": "RS256", "kid": kid}) + "." + enc(claims)
	digest := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func TestVerify(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	now := time.Unix(1_800_000_000, 0)
	v := NewVerifier(Apple("app.relaymsg"))
	v.SetKeys(map[string]*rsa.PublicKey{"k1": &key.PublicKey}, func() time.Time { return now })
	nonce := "raw-nonce"
	hashed := fmt.Sprintf("%x", sha256.Sum256([]byte(nonce)))
	good := map[string]any{"iss": "https://appleid.apple.com", "aud": "app.relaymsg", "sub": "001.abc",
		"exp": now.Add(5 * time.Minute).Unix(), "iat": now.Unix(), "email": "a@privaterelay.appleid.com",
		"email_verified": "true", "nonce": hashed}
	c, err := v.Verify(context.Background(), sign(t, key, "k1", good), nonce)
	if err != nil || c.Subject != "001.abc" || !c.EmailVerified || c.Email != "a@privaterelay.appleid.com" {
		t.Fatalf("good token: %+v %v", c, err)
	}

	with := func(k string, val any) map[string]any {
		m := map[string]any{}
		for a, b := range good {
			m[a] = b
		}
		m[k] = val
		return m
	}
	bad := map[string]string{
		"wrong audience": sign(t, key, "k1", with("aud", "com.other")),
		"wrong issuer":   sign(t, key, "k1", with("iss", "https://evil.example")),
		"expired":        sign(t, key, "k1", with("exp", now.Add(-time.Hour).Unix())),
		"future iat":     sign(t, key, "k1", with("iat", now.Add(time.Hour).Unix())),
		"wrong nonce":    sign(t, key, "k1", with("nonce", "abc")),
		"other key":      sign(t, other, "k1", good),
		"unknown kid":    sign(t, key, "k9", good),
		"no sub":         sign(t, key, "k1", with("sub", "")),
		"garbage":        "a.b.c",
	}
	for name, tok := range bad {
		if _, err := v.Verify(context.Background(), tok, nonce); err == nil {
			t.Errorf("%s verified", name)
		}
	}
	// alg none / HS256 tricks.
	parts := strings.Split(sign(t, key, "k1", good), ".")
	none := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","kid":"k1"}`)) + "." + parts[1] + "."
	if _, err := v.Verify(context.Background(), none, nonce); err == nil {
		t.Error("alg none verified")
	}

	// Google: boolean email_verified, audience list, either issuer form.
	g := NewVerifier(Google("123.apps.googleusercontent.com"))
	g.SetKeys(map[string]*rsa.PublicKey{"g1": &key.PublicKey}, func() time.Time { return now })
	gt := sign(t, key, "g1", map[string]any{"iss": "accounts.google.com", "aud": []string{"123.apps.googleusercontent.com"},
		"sub": "1098", "exp": now.Add(time.Minute).Unix(), "iat": now.Unix(), "email": "x@gmail.com", "email_verified": true})
	if c, err := g.Verify(context.Background(), gt, ""); err != nil || c.Subject != "1098" || !c.EmailVerified {
		t.Fatalf("google: %+v %v", c, err)
	}
	unverified := sign(t, key, "g1", map[string]any{"iss": "https://accounts.google.com", "aud": "123.apps.googleusercontent.com",
		"sub": "1099", "exp": now.Add(time.Minute).Unix(), "iat": now.Unix(), "email": "y@gmail.com", "email_verified": false})
	if c, err := g.Verify(context.Background(), unverified, ""); err != nil || c.EmailVerified {
		t.Fatalf("unverified email: %+v %v", c, err)
	}
}
