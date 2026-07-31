// Package apns sends push notifications to Apple over HTTP/2 using
// token-based (.p8 / JWT ES256) authentication. The relay only ever sends a
// wake + the already-encrypted envelope; the device's Notification Service
// Extension decrypts it. Apple never sees plaintext.
package apns

import (
	"bytes"
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
	"os"
	"sync"
	"time"
)

const (
	hostSandbox    = "https://api.sandbox.push.apple.com"
	hostProduction = "https://api.push.apple.com"
)

type Pusher struct {
	teamID string
	keyID  string
	topic  string
	host   string
	key    *ecdsa.PrivateKey
	client *http.Client

	mu       sync.Mutex
	jwt      string
	jwtIssAt time.Time
}

// New loads the .p8 signing key and prepares a pusher. `production` selects
// Apple's production host; development (sandbox) builds must use sandbox.
func New(keyPath, keyID, teamID, topic string, production bool) (*Pusher, error) {
	pemBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("read apns key: %w", err)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("apns key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse apns key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns key is not an ECDSA key")
	}
	host := hostSandbox
	if production {
		host = hostProduction
	}
	return &Pusher{
		teamID: teamID, keyID: keyID, topic: topic, host: host, key: key,
		client: &http.Client{Timeout: 15 * time.Second},
	}, nil
}

// Push sends an alert notification carrying the base64 envelope for the NSE
// to decrypt. `deviceToken` is the hex APNs token the client registered.
func (p *Pusher) Push(deviceToken string, envelope []byte) error {
	payload, err := json.Marshal(map[string]any{
		"aps": map[string]any{
			// A placeholder the NSE replaces once it decrypts; mutable-content
			// lets the extension run and rewrite the title/body.
			"alert":           map[string]any{"body": "New message"},
			"mutable-content": 1,
			"sound":           "default",
		},
		// Custom key: the encrypted envelope (relay.v1.Envelope) for the NSE.
		"e": base64.StdEncoding.EncodeToString(envelope),
	})
	if err != nil {
		return err
	}

	jwt, err := p.authToken()
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, p.host+"/3/device/"+deviceToken, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", p.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("apns status %d: %s", resp.StatusCode, string(body))
	}
	return nil
}

// authToken returns a cached provider token, refreshing it before Apple's
// ~1h expiry (they reject tokens older than 1h and newer than a few minutes).
func (p *Pusher) authToken() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.jwt != "" && time.Since(p.jwtIssAt) < 45*time.Minute {
		return p.jwt, nil
	}
	now := time.Now()
	header := b64url(fmt.Appendf(nil, `{"alg":"ES256","kid":%q}`, p.keyID))
	claims := b64url(fmt.Appendf(nil, `{"iss":%q,"iat":%d}`, p.teamID, now.Unix()))
	signingInput := header + "." + claims

	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, p.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS ES256 signature is R‖S, each left-padded to 32 bytes.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	token := signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)

	p.jwt = token
	p.jwtIssAt = now
	return token, nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
