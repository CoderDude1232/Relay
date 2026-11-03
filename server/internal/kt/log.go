package kt

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

// The root log: an RFC 6962 Merkle log whose entries are each epoch's
// SMT root, so a client can check a newer head extends one it saw before.

// LogEntry is what the log records for one epoch.
func LogEntry(epoch uint64, smtRoot [32]byte) []byte {
	out := make([]byte, 8, 40)
	binary.BigEndian.PutUint64(out, epoch)
	return append(out, smtRoot[:]...)
}

func logLeafHash(entry []byte) [32]byte {
	return sha256.Sum256(append([]byte{0x00}, entry...))
}

func logNodeHash(left, right [32]byte) [32]byte {
	b := make([]byte, 0, 65)
	b = append(b, 0x01)
	b = append(b, left[:]...)
	b = append(b, right[:]...)
	return sha256.Sum256(b)
}

// largestPow2Below is the largest power of two strictly less than n (n > 1).
func largestPow2Below(n int) int {
	k := 1
	for k<<1 < n {
		k <<= 1
	}
	return k
}

// LogRoot is MTH(entries) from RFC 6962 §2.1.
func LogRoot(leaves [][32]byte) [32]byte {
	switch len(leaves) {
	case 0:
		return sha256.Sum256(nil)
	case 1:
		return leaves[0]
	}
	k := largestPow2Below(len(leaves))
	return logNodeHash(LogRoot(leaves[:k]), LogRoot(leaves[k:]))
}

// ConsistencyProof proves the log of size n extends the one of size m
// (RFC 6962 §2.1.2). leaves are the leaf hashes of the larger log.
func ConsistencyProof(leaves [][32]byte, m int) [][32]byte {
	if m <= 0 || m >= len(leaves) {
		return nil
	}
	return subproof(leaves, m, true)
}

func subproof(leaves [][32]byte, m int, complete bool) [][32]byte {
	n := len(leaves)
	if m == n {
		if complete {
			return nil
		}
		return [][32]byte{LogRoot(leaves)}
	}
	k := largestPow2Below(n)
	if m <= k {
		return append(subproof(leaves[:k], m, complete), LogRoot(leaves[k:]))
	}
	return append(subproof(leaves[k:], m-k, false), LogRoot(leaves[:k]))
}

var errConsistency = errors.New("kt: logs are not consistent")

// VerifyConsistency checks that the log with root newRoot (size n) extends the
// one with root oldRoot (size m), RFC 9162 §2.1.4.2.
func VerifyConsistency(m, n int, oldRoot, newRoot [32]byte, proof [][32]byte) error {
	if m < 1 || m > n {
		return errConsistency
	}
	if m == n {
		if len(proof) != 0 || oldRoot != newRoot {
			return errConsistency
		}
		return nil
	}
	if m&(m-1) == 0 { // power of two: the old root is the first node
		proof = append([][32]byte{oldRoot}, proof...)
	}
	if len(proof) == 0 {
		return errConsistency
	}
	fn, sn := m-1, n-1
	for fn&1 == 1 {
		fn >>= 1
		sn >>= 1
	}
	fr, sr := proof[0], proof[0]
	for _, c := range proof[1:] {
		if sn == 0 {
			return errConsistency
		}
		if fn&1 == 1 || fn == sn {
			fr = logNodeHash(c, fr)
			sr = logNodeHash(c, sr)
			for fn != 0 && fn&1 == 0 {
				fn >>= 1
				sn >>= 1
			}
		} else {
			sr = logNodeHash(sr, c)
		}
		fn >>= 1
		sn >>= 1
	}
	if sn != 0 || fr != oldRoot || sr != newRoot {
		return errConsistency
	}
	return nil
}

// MARK: signed heads

// Head is the published state at one epoch.
type Head struct {
	Epoch   uint64
	SMTRoot [32]byte
	LogSize uint64
	LogRoot [32]byte
	Time    uint64 // unix seconds
	Sig     []byte
}

func (h Head) signedBytes() []byte {
	b := []byte("relay-kt-head-v1")
	var n [8]byte
	binary.BigEndian.PutUint64(n[:], h.Epoch)
	b = append(b, n[:]...)
	b = append(b, h.SMTRoot[:]...)
	binary.BigEndian.PutUint64(n[:], h.LogSize)
	b = append(b, n[:]...)
	b = append(b, h.LogRoot[:]...)
	binary.BigEndian.PutUint64(n[:], h.Time)
	return append(b, n[:]...)
}

func (h *Head) Sign(key ed25519.PrivateKey) {
	h.Sig = ed25519.Sign(key, h.signedBytes())
}

func (h Head) Verify(pub ed25519.PublicKey) bool {
	return ed25519.Verify(pub, h.signedBytes(), h.Sig)
}

// MARK: witness co-signatures and key endorsements

// WitnessBytes is what the independent witness signs for a head it has
// checked extends every head it saw before.
func (h Head) WitnessBytes() []byte {
	return append([]byte("relay-kt-witness-v1"), h.signedBytes()[len("relay-kt-head-v1"):]...)
}

// Endorsement says a key (Key) may sign in place of an older trusted one
// (By): how a signing key is replaced without an app update.
type Endorsement struct {
	Key []byte `json:"key"`
	By  []byte `json:"by"`
	Sig []byte `json:"sig"`
}

func endorsementBytes(purpose string, key []byte) []byte {
	return append([]byte("relay-kt-endorse-v1|"+purpose+"|"), key...)
}

// Endorse signs `key` with `by` for `purpose` ("head" or "witness").
func Endorse(purpose string, by ed25519.PrivateKey, key ed25519.PublicKey) Endorsement {
	return Endorsement{Key: key, By: by.Public().(ed25519.PublicKey), Sig: ed25519.Sign(by, endorsementBytes(purpose, key))}
}

// TrustedKeys extends `roots` with every endorsed key, in order: each must be
// endorsed by a key already trusted.
func TrustedKeys(purpose string, roots []ed25519.PublicKey, endorsements []Endorsement) []ed25519.PublicKey {
	trusted := append([]ed25519.PublicKey{}, roots...)
	for _, e := range endorsements {
		for _, t := range trusted {
			if bytes.Equal(t, e.By) && len(e.Key) == ed25519.PublicKeySize &&
				ed25519.Verify(t, endorsementBytes(purpose, e.Key), e.Sig) {
				trusted = append(trusted, ed25519.PublicKey(e.Key))
				break
			}
		}
	}
	return trusted
}

// VerifyAny checks the head against any of `keys`.
func (h Head) VerifyAny(keys []ed25519.PublicKey) bool {
	for _, k := range keys {
		if h.Verify(k) {
			return true
		}
	}
	return false
}
