// Package pinguard is the relay's half of the Relay PIN lock: a per-device
// oblivious PRF over ristretto255 (RFC 9496) that limits how many PINs can be
// tried (docs/DISTRESS_PIN_PLAN.md).
//
// The device blinds H(PIN) with a random scalar r and sends B = r·H(PIN). The
// relay answers E = k_d·B with the device's own secret scalar k_d and counts
// the attempt; the device unblinds to k_d·H(PIN) and mixes it with a secret
// that never leaves the iPhone to unwrap its database key. The relay never
// sees the PIN, and without k_d a copy of the device can't test PINs offline.
// After MaxAttempts evaluations with no correct PIN in between, the relay
// deletes k_d and the data it protected is gone for good.
package pinguard

import (
	"crypto/rand"
	"errors"
	"fmt"

	"github.com/gtank/ristretto255"
)

// MaxAttempts is how many PINs may be tried between correct ones.
const MaxAttempts = 10

// VerifierSize is the length of the tag a device proves a correct PIN with.
const VerifierSize = 32

// ErrBadElement: the blinded element isn't a valid, non-identity point.
var ErrBadElement = errors.New("pinguard: bad blinded element")

// NewScalar returns a fresh secret scalar, encoded (32 bytes).
func NewScalar() ([]byte, error) {
	var b [64]byte
	if _, err := rand.Read(b[:]); err != nil {
		return nil, fmt.Errorf("pinguard: crypto/rand failed: %w", err)
	}
	return ristretto255.NewScalar().FromUniformBytes(b[:]).Encode(nil), nil
}

// Evaluate returns k·B for the encoded scalar k and blinded element B.
func Evaluate(scalar, blinded []byte) ([]byte, error) {
	k := ristretto255.NewScalar()
	if err := k.Decode(scalar); err != nil {
		return nil, fmt.Errorf("pinguard: bad stored scalar: %w", err)
	}
	b := ristretto255.NewElement()
	if err := b.Decode(blinded); err != nil {
		return nil, ErrBadElement
	}
	// The identity would answer with the identity for every key.
	if b.Equal(ristretto255.NewElement().Zero()) == 1 {
		return nil, ErrBadElement
	}
	return ristretto255.NewElement().ScalarMult(k, b).Encode(nil), nil
}
