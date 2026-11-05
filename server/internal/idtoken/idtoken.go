// Package idtoken verifies Sign in with Apple and Google ID tokens (RS256
// JWTs) against the provider's published keys, so relayd can trust the
// account a token names without a sign-in service in between.
package idtoken

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Provider is one issuer's settings.
type Provider struct {
	Name     string   // "apple" or "google", the link prefix
	JWKSURL  string   // where its signing keys are published
	Issuers  []string // accepted iss values
	Audience string   // our client id (the bundle id for Apple)
}

// Apple is Sign in with Apple for a native app with this bundle id.
func Apple(bundleID string) Provider {
	return Provider{Name: "apple", JWKSURL: "https://appleid.apple.com/auth/keys",
		Issuers: []string{"https://appleid.apple.com"}, Audience: bundleID}
}

// Google is Google sign-in for this OAuth client id.
func Google(clientID string) Provider {
	return Provider{Name: "google", JWKSURL: "https://www.googleapis.com/oauth2/v3/certs",
		Issuers: []string{"https://accounts.google.com", "accounts.google.com"}, Audience: clientID}
}

// Claims is what the relay uses from a verified token.
type Claims struct {
	Subject       string
	Email         string
	EmailVerified bool
	Nonce         string
}

// ErrInvalid covers every token that doesn't verify.
var ErrInvalid = errors.New("idtoken: invalid token")

// Verifier checks tokens for one provider, caching its keys.
type Verifier struct {
	p      Provider
	client *http.Client
	now    func() time.Time

	mu        sync.Mutex
	keys      map[string]*rsa.PublicKey
	fetchedAt time.Time
}

// NewVerifier makes a verifier for p.
func NewVerifier(p Provider) *Verifier {
	return &Verifier{p: p, client: &http.Client{Timeout: 10 * time.Second}, now: time.Now}
}

// Name is the provider's name.
func (v *Verifier) Name() string { return v.p.Name }

const (
	keysMaxAge     = time.Hour
	keysMinRefetch = time.Minute
	clockSkew      = 2 * time.Minute
)

// Verify checks token's signature, issuer, audience and expiry. When
// wantNonce is set, the token's nonce must equal the hex SHA-256 of it (how
// Sign in with Apple carries the app's nonce).
func (v *Verifier) Verify(ctx context.Context, token, wantNonce string) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 || len(token) > 16<<10 {
		return Claims{}, ErrInvalid
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if !decodePart(parts[0], &header) || header.Alg != "RS256" || header.Kid == "" {
		return Claims{}, ErrInvalid
	}
	key, err := v.key(ctx, header.Kid)
	if err != nil {
		return Claims{}, err
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return Claims{}, ErrInvalid
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig) != nil {
		return Claims{}, ErrInvalid
	}
	var body struct {
		Iss           string          `json:"iss"`
		Aud           json.RawMessage `json:"aud"`
		Sub           string          `json:"sub"`
		Exp           int64           `json:"exp"`
		Iat           int64           `json:"iat"`
		Email         string          `json:"email"`
		EmailVerified any             `json:"email_verified"` // Apple sends "true", Google true
		Nonce         string          `json:"nonce"`
	}
	if !decodePart(parts[1], &body) || body.Sub == "" {
		return Claims{}, ErrInvalid
	}
	issOK := false
	for _, iss := range v.p.Issuers {
		issOK = issOK || body.Iss == iss
	}
	if !issOK || !audienceMatches(body.Aud, v.p.Audience) {
		return Claims{}, ErrInvalid
	}
	now := v.now()
	if body.Exp == 0 || now.After(time.Unix(body.Exp, 0).Add(clockSkew)) || time.Unix(body.Iat, 0).After(now.Add(clockSkew)) {
		return Claims{}, ErrInvalid
	}
	if wantNonce != "" {
		sum := sha256.Sum256([]byte(wantNonce))
		if body.Nonce != fmt.Sprintf("%x", sum) {
			return Claims{}, ErrInvalid
		}
	}
	verified := body.EmailVerified == true || body.EmailVerified == "true"
	return Claims{Subject: body.Sub, Email: body.Email, EmailVerified: verified && body.Email != "", Nonce: body.Nonce}, nil
}

func decodePart(part string, v any) bool {
	raw, err := base64.RawURLEncoding.DecodeString(part)
	return err == nil && json.Unmarshal(raw, v) == nil
}

func audienceMatches(raw json.RawMessage, want string) bool {
	if want == "" {
		return false
	}
	var one string
	if json.Unmarshal(raw, &one) == nil {
		return one == want
	}
	var many []string
	if json.Unmarshal(raw, &many) == nil {
		for _, a := range many {
			if a == want {
				return true
			}
		}
	}
	return false
}

// key returns the signing key kid, fetching the key set when it's stale or
// doesn't have kid (keys rotate), at most once a minute.
func (v *Verifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if k, ok := v.keys[kid]; ok && v.now().Sub(v.fetchedAt) < keysMaxAge {
		return k, nil
	}
	if v.now().Sub(v.fetchedAt) >= keysMinRefetch {
		keys, err := v.fetch(ctx)
		if err != nil {
			if k, ok := v.keys[kid]; ok {
				return k, nil // keep using a known key while the provider is unreachable
			}
			return nil, err
		}
		v.keys, v.fetchedAt = keys, v.now()
	}
	if k, ok := v.keys[kid]; ok {
		return k, nil
	}
	return nil, ErrInvalid
}

func (v *Verifier) fetch(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.p.JWKSURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("idtoken: %s keys: HTTP %d", v.p.Name, resp.StatusCode)
	}
	return ParseJWKS(io.LimitReader(resp.Body, 1<<20))
}

// ParseJWKS reads the RSA keys from a JSON Web Key Set.
func ParseJWKS(r io.Reader) (map[string]*rsa.PublicKey, error) {
	var set struct {
		Keys []struct {
			Kty, Kid, N, E string
		} `json:"keys"`
	}
	if err := json.NewDecoder(r).Decode(&set); err != nil {
		return nil, err
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" || k.Kid == "" {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil || len(e) > 4 || len(n) < 256 {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	if len(keys) == 0 {
		return nil, errors.New("idtoken: no usable keys")
	}
	return keys, nil
}

// SetKeys installs keys directly (tests).
func (v *Verifier) SetKeys(keys map[string]*rsa.PublicKey, now func() time.Time) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.keys, v.fetchedAt = keys, now()
	v.now = now
}
