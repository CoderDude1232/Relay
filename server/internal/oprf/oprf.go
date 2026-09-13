// Package oprf implements the server half of a 2HashDH oblivious PRF over
// ristretto255 (RFC 9496), used for blinded directory discovery.
//
// The relay holds a long-term secret scalar k. A client that wants to look up
// an identifier x (a normalized username or email) never sends x: it blinds
// H1(x) with a random scalar r and sends B = r·H1(x); the server returns
// E = k·B; the client unblinds to N = r⁻¹·E = k·H1(x) and derives the lookup
// token t = H2(x, N). The server can compute the same t directly from x (it
// knows its own users' identifiers) to build the directory index, so lookups
// match without the server ever seeing the identifiers a client queries — and
// non-registered identifiers reveal nothing (their token matches nothing).
package oprf

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/gtank/ristretto255"
)

// Domain-separation tags. Both the server and the client MUST use these exact
// strings and the same identifier normalization (Normalize) or tokens won't match.
const (
	hashToGroupDomain = "Relay-OPRF-v1-h2g"
	tokenDomain       = "Relay-OPRF-v1-token"
)

// Key is the relay's secret OPRF scalar.
type Key struct {
	scalar *ristretto255.Scalar
}

// Generate returns a fresh random OPRF key.
func Generate() (*Key, error) {
	var b [64]byte
	if _, err := rand.Read(b[:]); err != nil {
		return nil, fmt.Errorf("oprf: crypto/rand failed: %w", err)
	}
	return &Key{scalar: ristretto255.NewScalar().FromUniformBytes(b[:])}, nil
}

// LoadOrCreateKey reads a hex-encoded 32-byte scalar from path, generating and
// persisting a new one (0600) if the file doesn't exist. Losing this key
// invalidates the entire directory index (it must be rebuilt), but reveals
// nothing on its own.
func LoadOrCreateKey(path string) (*Key, error) {
	data, err := os.ReadFile(path)
	if err == nil {
		raw, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil {
			return nil, fmt.Errorf("oprf: decode key file: %w", err)
		}
		s := ristretto255.NewScalar()
		if err := s.Decode(raw); err != nil {
			return nil, fmt.Errorf("oprf: invalid key: %w", err)
		}
		return &Key{scalar: s}, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("oprf: read key file: %w", err)
	}
	k, err := Generate()
	if err != nil {
		return nil, err
	}
	enc := hex.EncodeToString(k.scalar.Encode(nil))
	if err := os.WriteFile(path, []byte(enc), 0o600); err != nil {
		return nil, fmt.Errorf("oprf: persist key: %w", err)
	}
	return k, nil
}

// Normalize canonicalizes an identifier so the client and server derive the
// same token from the "same" username/email regardless of case or padding.
func Normalize(identifier string) string {
	return strings.ToLower(strings.TrimSpace(identifier))
}

// hashToGroup maps arbitrary bytes to a ristretto255 element via SHA-512.
func hashToGroup(x []byte) *ristretto255.Element {
	h := sha512.New()
	h.Write([]byte(hashToGroupDomain))
	h.Write(x)
	return ristretto255.NewElement().FromUniformBytes(h.Sum(nil))
}

// Evaluate computes E = k·B for a client's blinded element B (raw 32-byte
// canonical ristretto encoding) and returns E's canonical encoding. The server
// learns nothing about the underlying identifier.
func (k *Key) Evaluate(blinded []byte) ([]byte, error) {
	b := ristretto255.NewElement()
	if err := b.Decode(blinded); err != nil {
		return nil, fmt.Errorf("oprf: bad blinded element: %w", err)
	}
	return ristretto255.NewElement().ScalarMult(k.scalar, b).Encode(nil), nil
}

// Token computes the directory token for a plaintext identifier: the same value
// a client derives obliviously. `identifier` is normalized internally.
func (k *Key) Token(identifier string) []byte {
	x := []byte(Normalize(identifier))
	n := ristretto255.NewElement().ScalarMult(k.scalar, hashToGroup(x))
	h := sha256.New()
	h.Write([]byte(tokenDomain))
	h.Write(x)
	h.Write(n.Encode(nil))
	return h.Sum(nil)
}
