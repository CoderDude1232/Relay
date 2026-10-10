// Package fcm sends push notifications to Android devices via Firebase Cloud
// Messaging (HTTP v1), with the same privacy model as package apns: the
// default push is a data-only wake with no message data, and the device fetches
// the encrypted envelope from the relay itself. A device that opted in to
// ciphertext-in-push gets the base64 envelope under data key "e", as in APNs.
package fcm

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
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
	"sync"
	"time"
)

// maxDataEnvelopeB64 caps the base64 envelope we'll embed in an opt-in push.
// FCM's total data payload limit is 4 KB; we stay well under it to leave room
// for JSON framing and other keys. Larger envelopes silently degrade to a
// content-free wake (the device fetches them from the queue instead).
const maxDataEnvelopeB64 = 3500

const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

type Pusher struct {
	projectID   string
	clientEmail string
	tokenURI    string
	key         *rsa.PrivateKey
	client      *http.Client

	mu       sync.Mutex
	token    string
	tokenExp time.Time
}

// serviceAccount is the subset of a Google service-account JSON we need.
type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// New loads a Firebase service-account JSON key file and prepares a pusher.
func New(serviceAccountPath string) (*Pusher, error) {
	raw, err := os.ReadFile(serviceAccountPath)
	if err != nil {
		return nil, fmt.Errorf("read fcm service account: %w", err)
	}
	var sa serviceAccount
	if err := json.Unmarshal(raw, &sa); err != nil {
		return nil, fmt.Errorf("parse fcm service account: %w", err)
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, errors.New("fcm service account missing project_id/client_email/private_key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, errors.New("fcm private_key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse fcm private key: %w", err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("fcm private_key is not an RSA key")
	}
	return &Pusher{
		projectID:   sa.ProjectID,
		clientEmail: sa.ClientEmail,
		tokenURI:    sa.TokenURI,
		key:         key,
		client:      &http.Client{Timeout: 15 * time.Second},
	}, nil
}

// Push wakes an Android device. A nil/empty envelope sends a content-free
// data-only wake; a non-nil envelope is embedded (base64) under data "e" unless
// it exceeds the FCM size budget, in which case it degrades to a wake.
func (p *Pusher) Push(deviceToken string, envelope []byte) error {
	data := map[string]string{"type": "wake"}
	if len(envelope) > 0 {
		b64 := base64.StdEncoding.EncodeToString(envelope)
		if len(b64) <= maxDataEnvelopeB64 {
			data = map[string]string{"type": "msg", "e": b64}
		}
		// Too big for the payload: fall back to the content-free wake.
	}
	return p.send(deviceToken, data)
}

// PushCall wakes an Android device for an incoming call (Android has no VoIP
// push). The data payload is only {"type": "call", "call_id": "<id>"}: no
// caller account, name or kind reaches Google. The client rings generically
// and learns the caller from the end-to-end-encrypted offer.
func (p *Pusher) PushCall(deviceToken, callID string) error {
	return p.send(deviceToken, map[string]string{"type": "call", "call_id": callID})
}

// send posts a data-only, high-priority FCM message. There is no "notification"
// block, so the app, not the OS, decides what to display.
func (p *Pusher) send(deviceToken string, data map[string]string) error {
	body, err := json.Marshal(map[string]any{
		"message": map[string]any{
			"token":   deviceToken,
			"android": map[string]any{"priority": "high"},
			"data":    data,
		},
	})
	if err != nil {
		return err
	}

	tok, err := p.accessToken()
	if err != nil {
		return err
	}
	endpoint := "https://fcm.googleapis.com/v1/projects/" + p.projectID + "/messages:send"
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		err := fmt.Errorf("fcm status %d: %s", resp.StatusCode, string(msg))
		// 404 NOT_FOUND / UNREGISTERED: the registration token is dead (app
		// uninstalled or token rotated). Signal it so the caller clears it.
		if resp.StatusCode == http.StatusNotFound || bytes.Contains(msg, []byte("UNREGISTERED")) {
			return &tokenError{err}
		}
		return err
	}
	return nil
}

// tokenError marks a send failure caused by a permanently invalid token; the
// hub detects it via the TokenInvalid() method.
type tokenError struct{ error }

func (e *tokenError) Unwrap() error      { return e.error }
func (e *tokenError) TokenInvalid() bool { return true }

// accessToken returns a cached OAuth2 access token, minting a fresh one from a
// signed service-account JWT when the cached one is near expiry.
func (p *Pusher) accessToken() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.token != "" && time.Until(p.tokenExp) > 5*time.Minute {
		return p.token, nil
	}

	now := time.Now()
	header := b64url([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims := b64url(fmt.Appendf(nil,
		`{"iss":%q,"scope":%q,"aud":%q,"iat":%d,"exp":%d}`,
		p.clientEmail, fcmScope, p.tokenURI, now.Unix(), now.Add(time.Hour).Unix()))
	signingInput := header + "." + claims
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, p.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	assertion := signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)

	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	resp, err := p.client.PostForm(p.tokenURI, form)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("fcm token status %d: %s", resp.StatusCode, string(msg))
	}
	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil {
		return "", err
	}
	if tr.AccessToken == "" {
		return "", errors.New("fcm token response had no access_token")
	}
	p.token = tr.AccessToken
	p.tokenExp = now.Add(time.Duration(tr.ExpiresIn) * time.Second)
	return p.token, nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
