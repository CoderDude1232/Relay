// Package voprf is the blind-token construction behind Relay Supporter
// credentials and anonymous send tokens: the Privacy Pass VOPRF (RFC 9497/9578)
// over ristretto255 with a DLEQ proof, under each caller's own domain tags.
//
// The client blinds B = r·H(label, nonce); the issuer answers E = k·B with a
// proof that it used the key behind Y = k·G; the client unblinds N = r⁻¹·E and
// later presents (label, nonce, N), which the issuer checks as
// N = k·H(label, nonce) without having seen nonce or N before.
package voprf

import (
	"crypto/rand"
	"crypto/sha512"
	"errors"

	"github.com/gtank/ristretto255"
)

// Suite is one use's domain tags.
type Suite struct {
	H2G  string
	DLEQ string
}

// HashToGroup is H(label, nonce).
func (s Suite) HashToGroup(label string, nonce []byte) *ristretto255.Element {
	h := sha512.New()
	h.Write([]byte(s.H2G))
	h.Write([]byte(label))
	h.Write([]byte{0})
	h.Write(nonce)
	return ristretto255.NewElement().FromUniformBytes(h.Sum(nil))
}

func (s Suite) challenge(y, b, e, a1, a2 *ristretto255.Element) *ristretto255.Scalar {
	h := sha512.New()
	h.Write([]byte(s.DLEQ))
	for _, p := range []*ristretto255.Element{y, b, e, a1, a2} {
		h.Write(p.Encode(nil))
	}
	return ristretto255.NewScalar().FromUniformBytes(h.Sum(nil))
}

// DecodePoint decodes a non-identity element.
func DecodePoint(raw []byte) (*ristretto255.Element, error) {
	p := ristretto255.NewElement()
	if len(raw) != 32 || p.Decode(raw) != nil || p.Equal(ristretto255.NewIdentityElement()) == 1 {
		return nil, errors.New("voprf: bad point")
	}
	return p, nil
}

// RandomScalar is a uniformly random scalar.
func RandomScalar() *ristretto255.Scalar {
	var b [64]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("voprf: crypto/rand failed: " + err.Error())
	}
	return ristretto255.NewScalar().FromUniformBytes(b[:])
}

// PublicKey is Y = k·G.
func PublicKey(k *ristretto255.Scalar) []byte {
	return ristretto255.NewElement().ScalarBaseMult(k).Encode(nil)
}

// Evaluate signs one blinded element: E = k·B, with proof c ‖ s (64 bytes)
// that log_G(Y) = log_B(E).
func (s Suite) Evaluate(k *ristretto255.Scalar, blinded []byte) (evaluated, proof []byte, err error) {
	b, err := DecodePoint(blinded)
	if err != nil {
		return nil, nil, err
	}
	y := ristretto255.NewElement().ScalarBaseMult(k)
	e := ristretto255.NewElement().ScalarMult(k, b)
	r := RandomScalar()
	a1 := ristretto255.NewElement().ScalarBaseMult(r)
	a2 := ristretto255.NewElement().ScalarMult(r, b)
	c := s.challenge(y, b, e, a1, a2)
	sc := ristretto255.NewScalar().Subtract(r, ristretto255.NewScalar().Multiply(c, k))
	return e.Encode(nil), append(c.Encode(nil), sc.Encode(nil)...), nil
}

// VerifyProof is the client's check of Evaluate (here for tests).
func (s Suite) VerifyProof(publicKey, blinded, evaluated, proof []byte) bool {
	y, err1 := DecodePoint(publicKey)
	b, err2 := DecodePoint(blinded)
	e, err3 := DecodePoint(evaluated)
	if err1 != nil || err2 != nil || err3 != nil || len(proof) != 64 {
		return false
	}
	c, sc := ristretto255.NewScalar(), ristretto255.NewScalar()
	if c.Decode(proof[:32]) != nil || sc.Decode(proof[32:]) != nil {
		return false
	}
	a1 := ristretto255.NewElement().Add(
		ristretto255.NewElement().ScalarBaseMult(sc), ristretto255.NewElement().ScalarMult(c, y))
	a2 := ristretto255.NewElement().Add(
		ristretto255.NewElement().ScalarMult(sc, b), ristretto255.NewElement().ScalarMult(c, e))
	return s.challenge(y, b, e, a1, a2).Equal(c) == 1
}

// Check verifies a presented token: point = k·H(label, nonce).
func (s Suite) Check(k *ristretto255.Scalar, label string, nonce, point []byte) bool {
	n, err := DecodePoint(point)
	if err != nil {
		return false
	}
	want := ristretto255.NewElement().ScalarMult(k, s.HashToGroup(label, nonce))
	return want.Equal(n) == 1
}
