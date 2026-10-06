package oprf

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"strings"
)

// Bucketed directory entries — the address-book-hiding half of blinded
// discovery. After the oblivious OPRF evaluation the client holds token t for
// each identifier, but it NEVER sends t. It sends only bucket(t), a 16-bit
// prefix shared by many identifiers (registered or not). For each requested
// bucket the relay returns every entry it holds as {tag, box}; the client
// recomputes tag(t) locally, finds its match (if any), and opens the box with
// a key only a holder of t can derive. The relay learns at most which buckets
// were asked about — never which identifier, and never whether it matched.
//
// All derivations are keyed on the 32-byte token t (clients MUST match these
// byte-for-byte; see RelayKit/Sources/RelayKit/DirectoryBuckets.swift):
//
//	bucket(t) = big-endian uint16 of SHA-256("relay-bucket" ‖ t)[0:2]
//	tag(t)    = HMAC-SHA256(key = t, msg = "relay-tag")[0:8]
//	key(t)    = HKDF-SHA256(ikm = t, salt = none, info = "relay-entry", 32 bytes)
//	box       = nonce(12) ‖ AES-256-GCM(key(t), nonce, accountId ‖ "\n" ‖ username)
//
// Boxes are sealed once, at index time, so a bucket fetch is a plain read.
const (
	bucketDomain = "relay-bucket"
	tagMessage   = "relay-tag"
	entryInfo    = "relay-entry"

	// DirectoryTagLen is the truncated tag length in bytes.
	DirectoryTagLen = 8
)

// DirectoryBucket returns the 16-bit bucket for a token.
func DirectoryBucket(token []byte) uint16 {
	h := sha256.New()
	h.Write([]byte(bucketDomain))
	h.Write(token)
	sum := h.Sum(nil)
	return uint16(sum[0])<<8 | uint16(sum[1])
}

// DirectoryTag returns the 8-byte match tag for a token.
func DirectoryTag(token []byte) []byte {
	m := hmac.New(sha256.New, token)
	m.Write([]byte(tagMessage))
	return m.Sum(nil)[:DirectoryTagLen]
}

func directoryEntryKey(token []byte) ([]byte, error) {
	return hkdf.Key(sha256.New, token, nil, entryInfo, 32)
}

func entryAEAD(token []byte) (cipher.AEAD, error) {
	key, err := directoryEntryKey(token)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// SealDirectoryEntry encrypts (accountID, username) under the token-derived key.
func SealDirectoryEntry(token []byte, accountID, username string) ([]byte, error) {
	aead, err := entryAEAD(token)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, []byte(accountID+"\n"+username), nil), nil
}

// OpenDirectoryEntry is the client-side inverse (used by tests and as the
// reference for other clients).
func OpenDirectoryEntry(token, box []byte) (accountID, username string, err error) {
	aead, err := entryAEAD(token)
	if err != nil {
		return "", "", err
	}
	if len(box) < aead.NonceSize()+aead.Overhead() {
		return "", "", errors.New("oprf: directory box too short")
	}
	pt, err := aead.Open(nil, box[:aead.NonceSize()], box[aead.NonceSize():], nil)
	if err != nil {
		return "", "", err
	}
	accountID, username, ok := strings.Cut(string(pt), "\n")
	if !ok {
		return "", "", errors.New("oprf: malformed directory entry")
	}
	return accountID, username, nil
}
