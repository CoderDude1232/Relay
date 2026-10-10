// Package sealedsender mints libsignal-compatible sealed-sender certificates so
// the relay can vouch for a sender's identity without authenticating (or
// learning) the sender on each message. Certificates are signed with XEd25519
// exactly as libsignal expects, so the vendored client validates them natively.
//
// The signature scheme is XEd25519 over Curve25519 keys, matching
// libsignal's PrivateKey::calculate_signature
// (third_party/libsignal/rust/core/src/curve/curve25519.rs): SHA-512, a 32-byte
// domain-separation prefix, and the public key's sign bit carried in the top bit
// of the signature's final byte for libsignal-protocol-java compatibility.
package sealedsender

import (
	"crypto/rand"
	"crypto/sha512"
	"errors"

	"filippo.io/edwards25519"
)

const signatureLen = 64

// hashPrefix is XEd25519's first-hash domain separator: 0xFE followed by 31 0xFF
// bytes. Must match libsignal byte-for-byte or signatures won't verify.
var hashPrefix = [32]byte{
	0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
}

// pad64 places a ≤64-byte little-endian value into a 64-byte buffer so it can be
// reduced mod l via SetUniformBytes (equivalent to dalek's from_bytes_mod_order).
func pad64(b []byte) []byte {
	out := make([]byte, 64)
	copy(out, b)
	return out
}

// signXEd25519 produces a 64-byte libsignal-compatible XEd25519 signature over
// message, using a clamped 32-byte Curve25519 private scalar.
func signXEd25519(privClamped, message []byte) ([]byte, error) {
	if len(privClamped) != 32 {
		return nil, errors.New("sealedsender: private key must be 32 bytes")
	}
	// a = private scalar (mod l); A = a·B (Edwards public), compressed.
	a, err := edwards25519.NewScalar().SetUniformBytes(pad64(privClamped))
	if err != nil {
		return nil, err
	}
	aPub := new(edwards25519.Point).ScalarBaseMult(a)
	aPubBytes := aPub.Bytes()
	signBit := aPubBytes[31] & 0x80

	var randomBytes [64]byte
	if _, err := rand.Read(randomBytes[:]); err != nil {
		return nil, err
	}

	// r = SHA512(prefix || key || message || random) mod l
	h1 := sha512.New()
	h1.Write(hashPrefix[:])
	h1.Write(privClamped)
	h1.Write(message)
	h1.Write(randomBytes[:])
	r, err := edwards25519.NewScalar().SetUniformBytes(h1.Sum(nil))
	if err != nil {
		return nil, err
	}
	capR := new(edwards25519.Point).ScalarBaseMult(r)
	capRBytes := capR.Bytes()

	// h = SHA512(R || A || message) mod l
	h2 := sha512.New()
	h2.Write(capRBytes)
	h2.Write(aPubBytes)
	h2.Write(message)
	hScalar, err := edwards25519.NewScalar().SetUniformBytes(h2.Sum(nil))
	if err != nil {
		return nil, err
	}

	// s = h·a + r (mod l)
	s := edwards25519.NewScalar().Multiply(hScalar, a)
	s.Add(s, r)
	sBytes := s.Bytes()

	sig := make([]byte, signatureLen)
	copy(sig[:32], capRBytes)
	copy(sig[32:], sBytes)
	sig[signatureLen-1] &= 0x7F
	sig[signatureLen-1] |= signBit
	return sig, nil
}

// verifyXEd25519 checks an XEd25519 signature using the Edwards public point
// directly. Used for internal round-trip self-tests; the authoritative verifier
// is libsignal on the client, which reconstructs the point from the Montgomery
// public key plus the signature's sign bit.
func verifyXEd25519(edPub *edwards25519.Point, message, sig []byte) bool {
	if len(sig) != signatureLen {
		return false
	}
	var rBytes [32]byte
	copy(rBytes[:], sig[:32])
	var sBytes [32]byte
	copy(sBytes[:], sig[32:])
	sBytes[31] &= 0x7F // strip the carried sign bit before reading s

	capR, err := new(edwards25519.Point).SetBytes(rBytes[:])
	if err != nil {
		return false
	}
	s, err := edwards25519.NewScalar().SetCanonicalBytes(sBytes[:])
	if err != nil {
		return false
	}

	h2 := sha512.New()
	h2.Write(rBytes[:])
	h2.Write(edPub.Bytes())
	h2.Write(message)
	hScalar, err := edwards25519.NewScalar().SetUniformBytes(h2.Sum(nil))
	if err != nil {
		return false
	}

	// Check s·B == R + h·A
	sB := new(edwards25519.Point).ScalarBaseMult(s)
	hA := new(edwards25519.Point).ScalarMult(hScalar, edPub)
	rPlusHA := new(edwards25519.Point).Add(capR, hA)
	return sB.Equal(rPlusHA) == 1
}
