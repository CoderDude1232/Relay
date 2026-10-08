// Package siwa revokes a user's Sign in with Apple tokens when their relay
// account is deleted (App Store Review Guideline 5.1.1(v)).
//
// The relay stores no Apple tokens. At deletion the client re-authenticates
// with Apple and passes the fresh, short-lived authorization code; the relay
// exchanges it at Apple's token endpoint for a refresh token and immediately
// revokes that, which ends the app's Sign in with Apple grant for the user.
// Both calls authenticate with a client secret: an ES256 JWT signed by the
// team's Sign in with Apple key (.p8). Neither the code nor any token is ever
// stored or logged.
package siwa

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Apple's endpoints (overridable on a Revoker for tests).
const (
	DefaultTokenURL  = "https://appleid.apple.com/auth/token"
	DefaultRevokeURL = "https://appleid.apple.com/auth/revoke"
	audience         = "https://appleid.apple.com"
)

// clientSecretTTL is the lifetime of each client-secret JWT. Apple allows up
// to six months; a fresh short-lived one is minted per revocation.
const clientSecretTTL = 5 * time.Minute

// maxResponseBytes bounds how much of an Apple response is read.
const maxResponseBytes = 64 << 10

// Revoker exchanges authorization codes and revokes the resulting tokens.
type Revoker struct {
	keyID    string
	teamID   string
	clientID string
	key      *ecdsa.PrivateKey

	// HTTP, TokenURL and RevokeURL are injectable for tests.
	HTTP      *http.Client
	TokenURL  string
	RevokeURL string
	now       func() time.Time
}

// New loads the Sign in with Apple .p8 key (PKCS#8 PEM, P-256) from keyPath.
// teamID is the Apple developer team id (the JWT issuer), clientID the app's
// bundle id / Services ID the codes were issued to (the JWT subject).
func New(keyPath, keyID, teamID, clientID string) (*Revoker, error) {
	pemBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("siwa: read key: %w", err)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("siwa: key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("siwa: parse key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("siwa: key is not an ECDSA key")
	}
	return NewWithKey(key, keyID, teamID, clientID)
}

// NewWithKey builds a Revoker around an already-parsed P-256 key.
func NewWithKey(key *ecdsa.PrivateKey, keyID, teamID, clientID string) (*Revoker, error) {
	if keyID == "" || teamID == "" || clientID == "" {
		return nil, errors.New("siwa: key id, team id and client id are required")
	}
	return &Revoker{
		keyID: keyID, teamID: teamID, clientID: clientID, key: key,
		HTTP:      &http.Client{Timeout: 10 * time.Second},
		TokenURL:  DefaultTokenURL,
		RevokeURL: DefaultRevokeURL,
		now:       time.Now,
	}, nil
}

// clientSecret mints the ES256 client-secret JWT Apple's endpoints require:
// header {alg: ES256, kid}, claims {iss: team id, iat, exp, aud:
// https://appleid.apple.com, sub: client id}.
func (r *Revoker) clientSecret() (string, error) {
	now := r.now()
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": r.keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"iss": r.teamID,
		"iat": now.Unix(),
		"exp": now.Add(clientSecretTTL).Unix(),
		"aud": audience,
		"sub": r.clientID,
	})
	if err != nil {
		return "", err
	}
	signingInput := b64url(header) + "." + b64url(claims)
	digest := sha256.Sum256([]byte(signingInput))
	rr, ss, err := ecdsa.Sign(rand.Reader, r.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS ES256 signature is R‖S, each left-padded to 32 bytes.
	sig := make([]byte, 64)
	rr.FillBytes(sig[:32])
	ss.FillBytes(sig[32:])
	return signingInput + "." + b64url(sig), nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// RevokeAuthorizationCode exchanges code for the user's tokens and revokes the
// refresh token (or, if Apple returned none, the access token). The returned
// error never contains the code or a token.
func (r *Revoker) RevokeAuthorizationCode(ctx context.Context, code string) error {
	secret, err := r.clientSecret()
	if err != nil {
		return fmt.Errorf("siwa: client secret: %w", err)
	}
	var tokens struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if err := r.post(ctx, r.TokenURL, url.Values{
		"client_id":     {r.clientID},
		"client_secret": {secret},
		"code":          {code},
		"grant_type":    {"authorization_code"},
	}, &tokens); err != nil {
		return fmt.Errorf("siwa: token exchange: %w", err)
	}
	token, hint := tokens.RefreshToken, "refresh_token"
	if token == "" {
		token, hint = tokens.AccessToken, "access_token"
	}
	if token == "" {
		return errors.New("siwa: token exchange returned no token")
	}
	if err := r.post(ctx, r.RevokeURL, url.Values{
		"client_id":       {r.clientID},
		"client_secret":   {secret},
		"token":           {token},
		"token_type_hint": {hint},
	}, nil); err != nil {
		return fmt.Errorf("siwa: revoke: %w", err)
	}
	return nil
}

// post sends a form POST and decodes a 200 JSON response into out (if non-nil).
// A non-200 answer becomes an error carrying only the status and Apple's
// short error code (e.g. "invalid_grant").
func (r *Revoker) post(ctx context.Context, endpoint string, form url.Values, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	// The code / tokens / secret travel only in the form body, so a transport
	// error (which names the endpoint URL) can't contain them.
	resp, err := r.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		var apiErr struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(body, &apiErr)
		return fmt.Errorf("HTTP %d %s", resp.StatusCode, sanitizeErrorCode(apiErr.Error))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(body, out)
}

// sanitizeErrorCode keeps Apple's error code only if it looks like one
// (lowercase letters and underscores), so nothing else can leak into logs.
func sanitizeErrorCode(code string) string {
	if len(code) > 40 {
		return ""
	}
	for _, c := range code {
		if (c < 'a' || c > 'z') && c != '_' {
			return ""
		}
	}
	return code
}
