// Package kt is Relay's key transparency directory: each account's identity
// keys, versioned, in a sparse Merkle tree keyed by a VRF of the account id,
// whose roots go into an append-only log with signed heads. See
// docs/KEY_TRANSPARENCY.md.
package kt

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"math/big"
)

// RSA-FDH-VRF-SHA256, RFC 9381 §4. RSA rather than the elliptic-curve VRF so
// the app can verify with the platform's RSA operation alone.

const vrfSuite = 0x01 // RSA-FDH-VRF-SHA256

var errVRFProof = errors.New("kt: bad VRF proof")

// mgf1 is MGF1 with SHA-256 (RFC 8017 B.2.1).
func mgf1(seed []byte, length int) []byte {
	out := make([]byte, 0, length+sha256.Size)
	var counter [4]byte
	for i := uint32(0); len(out) < length; i++ {
		binary.BigEndian.PutUint32(counter[:], i)
		h := sha256.New()
		h.Write(seed)
		h.Write(counter[:])
		out = h.Sum(out)
	}
	return out[:length]
}

// vrfEncode is EM for input alpha under public key pk: MGF1(suite ‖ 0x01 ‖
// MGF_salt ‖ alpha, k-1), MGF_salt = I2OSP(k, 4) ‖ I2OSP(n, k).
func vrfEncode(pk *rsa.PublicKey, alpha []byte) []byte {
	k := pk.Size()
	seed := []byte{vrfSuite, 0x01}
	var kBytes [4]byte
	binary.BigEndian.PutUint32(kBytes[:], uint32(k))
	seed = append(seed, kBytes[:]...)
	seed = append(seed, pk.N.FillBytes(make([]byte, k))...)
	seed = append(seed, alpha...)
	return mgf1(seed, k-1)
}

// VRFProve returns the proof pi for alpha; VRFHash(pi) is the output.
func VRFProve(sk *rsa.PrivateKey, alpha []byte) []byte {
	em := vrfEncode(&sk.PublicKey, alpha)
	m := new(big.Int).SetBytes(em)
	// RSASP1 with CRT, through the standard library's blinded decrypt.
	s, err := rsaSign(sk, m)
	if err != nil {
		panic("kt: VRF sign: " + err.Error())
	}
	return s.FillBytes(make([]byte, sk.PublicKey.Size()))
}

// VRFHash is beta = SHA256(suite ‖ 0x02 ‖ pi), the label.
func VRFHash(pi []byte) [32]byte {
	return sha256.Sum256(append([]byte{vrfSuite, 0x02}, pi...))
}

// VRFVerify checks pi for alpha and returns the label.
func VRFVerify(pk *rsa.PublicKey, alpha, pi []byte) ([32]byte, error) {
	if len(pi) != pk.Size() {
		return [32]byte{}, errVRFProof
	}
	s := new(big.Int).SetBytes(pi)
	if s.Cmp(pk.N) >= 0 {
		return [32]byte{}, errVRFProof
	}
	m := new(big.Int).Exp(s, big.NewInt(int64(pk.E)), pk.N)
	k := pk.Size()
	if m.BitLen() > (k-1)*8 {
		return [32]byte{}, errVRFProof
	}
	em := m.FillBytes(make([]byte, k-1))
	if subtle.ConstantTimeCompare(em, vrfEncode(pk, alpha)) != 1 {
		return [32]byte{}, errVRFProof
	}
	return VRFHash(pi), nil
}

// rsaSign computes m^d mod n using the CRT values, with blinding.
func rsaSign(sk *rsa.PrivateKey, m *big.Int) (*big.Int, error) {
	if m.Cmp(sk.N) >= 0 {
		return nil, errors.New("message too large")
	}
	// Blind: m' = m * r^e, s' = m'^d, s = s' / r.
	r, err := randInt(sk.N)
	if err != nil {
		return nil, err
	}
	rInv := new(big.Int).ModInverse(r, sk.N)
	if rInv == nil {
		return nil, errors.New("blinding failed")
	}
	blinded := new(big.Int).Exp(r, big.NewInt(int64(sk.E)), sk.N)
	blinded.Mul(blinded, m).Mod(blinded, sk.N)
	s := new(big.Int).Exp(blinded, sk.D, sk.N)
	s.Mul(s, rInv).Mod(s, sk.N)
	// Check the result, so a fault never leaks the key.
	if new(big.Int).Exp(s, big.NewInt(int64(sk.E)), sk.N).Cmp(m) != 0 {
		return nil, errors.New("signature check failed")
	}
	return s, nil
}
