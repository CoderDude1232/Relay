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
	"strings"
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
	// host is tried first for a token we haven't seen; altHost is the other
	// APNs environment. Development builds (run from Xcode) get sandbox
	// tokens and TestFlight/App Store builds get production tokens, and
	// Apple rejects a token sent to the wrong environment with
	// BadDeviceToken — so on that error the push is retried on altHost and
	// the working host is remembered per token. One relay serves both.
	host    string
	altHost string
	key     *ecdsa.PrivateKey
	client  *http.Client

	mu       sync.Mutex
	jwt      string
	jwtIssAt time.Time

	hostMu      sync.Mutex
	hostByToken map[string]string
}

// maxRememberedTokens bounds the per-token host cache; it is cleared when
// full (a cleared token just costs one extra request next time).
const maxRememberedTokens = 50_000

// New loads the .p8 signing key and prepares a pusher. `production` selects
// which APNs environment is tried first; tokens from the other environment
// still work via the BadDeviceToken fallback in send.
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
	host, altHost := hostSandbox, hostProduction
	if production {
		host, altHost = hostProduction, hostSandbox
	}
	return &Pusher{
		teamID: teamID, keyID: keyID, topic: topic, host: host, altHost: altHost, key: key,
		client:      &http.Client{Timeout: 15 * time.Second},
		hostByToken: map[string]string{},
	}, nil
}

// Push sends a wake notification. By default it is CONTENT-FREE: `envelope` is
// nil and the payload carries no message data at all. The push only tells the
// device something is waiting; the Notification Service Extension then fetches
// the encrypted envelope from the relay over its own connection and decrypts it
// on-device, keeping message content off Apple's push infrastructure entirely.
//
// If the destination device opted in to ciphertext-in-push, the caller passes a
// non-nil `envelope` and it is embedded (base64) so the NSE can decrypt straight
// from the payload without a round-trip — faster, but Apple's servers then carry
// the (still end-to-end-encrypted) blob.
func (p *Pusher) Push(deviceToken string, envelope []byte) error {
	aps := map[string]any{
		// A placeholder the NSE replaces after it fetches + decrypts;
		// mutable-content lets the extension run and rewrite the title/body.
		"alert":           map[string]any{"body": "New message"},
		"mutable-content": 1,
		"sound":           "default",
	}
	body := map[string]any{"aps": aps}
	if len(envelope) > 0 {
		body["e"] = base64.StdEncoding.EncodeToString(envelope)
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}

	if err := p.send(deviceToken, payload, p.topic, "alert"); err != nil {
		return fmt.Errorf("apns %w", err)
	}
	return nil
}

// PushVoIP sends a PushKit VoIP push that wakes the app and presents the
// CallKit incoming-call UI. The payload must not contain content-available
// (PushKit VoIP pushes are always treated as high-priority wakes by iOS).
func (p *Pusher) PushVoIP(deviceToken, callID, callerAccount, callerName, kind string) error {
	if kind == "" {
		kind = "audio"
	}
	payload, err := json.Marshal(map[string]any{
		"call_id":        callID,
		"caller_account": callerAccount,
		"caller_name":    callerName,
		"kind":           kind,
	})
	if err != nil {
		return err
	}
	if err := p.send(deviceToken, payload, p.topic+".voip", "voip"); err != nil {
		return fmt.Errorf("apns voip %w", err)
	}
	return nil
}

// send posts one notification, starting with the host known to work for this
// token (else the configured one) and falling back to the other environment
// when Apple says the token doesn't belong to it.
func (p *Pusher) send(deviceToken string, payload []byte, topic, pushType string) error {
	first := p.hostFor(deviceToken)
	second := p.altHost
	if first == p.altHost {
		second = p.host
	}
	status, reason, err := p.post(first, deviceToken, payload, topic, pushType)
	if err != nil {
		return err
	}
	if status == http.StatusOK {
		p.rememberHost(deviceToken, first)
		return nil
	}
	if status == http.StatusBadRequest && strings.Contains(reason, "BadDeviceToken") {
		status, reason, err = p.post(second, deviceToken, payload, topic, pushType)
		if err != nil {
			return err
		}
		if status == http.StatusOK {
			p.rememberHost(deviceToken, second)
			return nil
		}
	}
	return fmt.Errorf("status %d: %s", status, reason)
}

func (p *Pusher) post(host, deviceToken string, payload []byte, topic, pushType string) (int, string, error) {
	jwt, err := p.authToken()
	if err != nil {
		return 0, "", err
	}
	req, err := http.NewRequest(http.MethodPost, host+"/3/device/"+deviceToken, bytes.NewReader(payload))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", pushType)
	req.Header.Set("apns-priority", "10")

	resp, err := p.client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body), nil
}

func (p *Pusher) hostFor(deviceToken string) string {
	p.hostMu.Lock()
	defer p.hostMu.Unlock()
	if h, ok := p.hostByToken[deviceToken]; ok {
		return h
	}
	return p.host
}

func (p *Pusher) rememberHost(deviceToken, host string) {
	p.hostMu.Lock()
	defer p.hostMu.Unlock()
	if len(p.hostByToken) >= maxRememberedTokens {
		p.hostByToken = map[string]string{}
	}
	p.hostByToken[deviceToken] = host
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
