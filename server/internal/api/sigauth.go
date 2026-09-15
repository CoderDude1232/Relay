package api

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/store"
)

// Signature-based request authentication. Instead of presenting a reusable
// device password (HTTP Basic), a client signs each request with its P256 auth
// private key — the same keypair used for nuke commands, whose private half
// never leaves the device. The server verifies against the stored
// `auth_public_key`. Nothing replayable ever transits the wire, so a leaked log
// or a TLS-terminating hop can't capture a credential that works twice.
//
// Wire format:
//   Authorization: Relay-Sig <accountId>.<deviceId>:<base64(ECDSA-P256 sig)>
//   X-Relay-Timestamp: <unix millis>
//   X-Relay-Nonce:     <base64 random>
//
// The signature is ECDSA-P256 (ASN.1) over SHA-256 of the canonical string:
//   METHOD "\n" PATH "\n" TIMESTAMP "\n" NONCE
// The body is deliberately not signed (see TODO.md rationale). A request is
// accepted iff the signature validates, the timestamp is within ±sigAuthSkew,
// and the nonce hasn't been seen inside that window.
const sigAuthScheme = "Relay-Sig"

const sigAuthSkew = 5 * time.Minute

// nonceCache blocks replay of a captured signed request inside the skew window.
// A signature is only valid for its exact (method, path, timestamp, nonce), so
// remembering nonces for the skew window is enough — anything older is already
// rejected by the timestamp check.
type nonceCache struct {
	mu   sync.Mutex
	seen map[string]int64 // nonce key -> expiry (unix ms)
}

func newNonceCache() *nonceCache { return &nonceCache{seen: make(map[string]int64)} }

// checkAndStore returns false if the key was already seen (replay); otherwise it
// records the key until expiry and returns true.
func (c *nonceCache) checkAndStore(key string, nowMs, expiryMs int64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if exp, ok := c.seen[key]; ok && exp > nowMs {
		return false
	}
	// Opportunistic prune so the map can't grow unbounded.
	if len(c.seen) > 4096 {
		for k, exp := range c.seen {
			if exp <= nowMs {
				delete(c.seen, k)
			}
		}
	}
	c.seen[key] = expiryMs
	return true
}

var requestNonces = newNonceCache()

// authenticateSignature validates a Relay-Sig request and returns the device.
func (s *Server) authenticateSignature(r *http.Request) (*store.Device, error) {
	raw := strings.TrimPrefix(r.Header.Get("Authorization"), sigAuthScheme+" ")
	credPart, sigB64, ok := strings.Cut(raw, ":")
	if !ok {
		return nil, errors.New("malformed signature authorization")
	}
	accountID, devStr, ok := strings.Cut(credPart, ".")
	if !ok {
		return nil, errors.New("credential must be <accountID>.<deviceID>")
	}
	devID, err := strconv.ParseUint(devStr, 10, 32)
	if err != nil {
		return nil, errors.New("bad device id")
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		return nil, errors.New("bad signature encoding")
	}

	tsStr := r.Header.Get("X-Relay-Timestamp")
	nonce := r.Header.Get("X-Relay-Nonce")
	if tsStr == "" || nonce == "" {
		return nil, errors.New("missing timestamp or nonce")
	}
	tsMs, err := strconv.ParseInt(tsStr, 10, 64)
	if err != nil {
		return nil, errors.New("bad timestamp")
	}
	nowMs := time.Now().UnixMilli()
	if diff := nowMs - tsMs; diff > sigAuthSkew.Milliseconds() || diff < -sigAuthSkew.Milliseconds() {
		return nil, errors.New("timestamp outside allowed window")
	}

	dev, err := s.store.DeviceByID(accountID, uint32(devID))
	if err != nil {
		return nil, err
	}
	if len(dev.AuthPublicKey) == 0 {
		return nil, errors.New("device has no authorization key")
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), dev.AuthPublicKey)
	if x == nil || y == nil {
		return nil, errors.New("invalid device authorization key")
	}
	pub := ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	digest := sha256.Sum256([]byte(sigAuthCanonical(r.Method, r.URL.Path, tsStr, nonce)))
	if !ecdsa.VerifyASN1(&pub, digest[:], sig) {
		return nil, errors.New("signature verification failed")
	}

	// Bind the replay key to the device so two devices can't collide on a nonce.
	replayKey := accountID + "." + devStr + ":" + nonce
	if !requestNonces.checkAndStore(replayKey, nowMs, tsMs+sigAuthSkew.Milliseconds()) {
		return nil, errors.New("replayed nonce")
	}
	return dev, nil
}

// sigAuthCanonical builds the exact string the client signs. Clients MUST
// reproduce this byte-for-byte.
func sigAuthCanonical(method, path, timestamp, nonce string) string {
	return method + "\n" + path + "\n" + timestamp + "\n" + nonce
}
