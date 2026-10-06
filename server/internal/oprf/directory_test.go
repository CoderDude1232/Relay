package oprf

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// Fixed vectors so other clients (RelayKit's DirectoryBuckets.swift) can check
// their bucket/tag derivation byte-for-byte.
func TestDirectoryDerivationVectors(t *testing.T) {
	token := bytes.Repeat([]byte{0x42}, 32)
	if got := DirectoryBucket(token); got != directoryVectorBucket {
		t.Fatalf("bucket = %d (0x%04x)", got, got)
	}
	if got := hex.EncodeToString(DirectoryTag(token)); got != directoryVectorTag {
		t.Fatalf("tag = %s", got)
	}
	key, err := directoryEntryKey(token)
	if err != nil || hex.EncodeToString(key) != directoryVectorKey {
		t.Fatalf("entry key = %x (%v)", key, err)
	}
}

// Independently computed (Python hashlib/hmac) for token = 0x42 × 32.
const (
	directoryVectorBucket = 0xde0d
	directoryVectorTag    = "29f97dd6fe1965da"
	directoryVectorKey    = "c7b86232d122314163544dac008ad7cbb32ef9aa26253a2b859a4a6eb969d155"
)

func TestDirectoryEntryRoundTrip(t *testing.T) {
	token := bytes.Repeat([]byte{0x07}, 32)
	box, err := SealDirectoryEntry(token, "acct-id", "bob")
	if err != nil {
		t.Fatal(err)
	}
	acct, user, err := OpenDirectoryEntry(token, box)
	if err != nil || acct != "acct-id" || user != "bob" {
		t.Fatalf("round trip: %q %q %v", acct, user, err)
	}
	other := bytes.Repeat([]byte{0x08}, 32)
	if _, _, err := OpenDirectoryEntry(other, box); err == nil {
		t.Fatal("box opened with the wrong token")
	}
	if bytes.Equal(DirectoryTag(token), DirectoryTag(other)) {
		t.Fatal("distinct tokens share a tag")
	}
}
