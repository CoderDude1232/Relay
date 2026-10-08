package oprf

import (
	"bytes"
	"testing"
)

func TestDeriveKey(t *testing.T) {
	k1, _ := Generate()
	k2, _ := Generate()
	a := k1.DeriveKey("released-username")
	if len(a) != 32 || !bytes.Equal(a, k1.DeriveKey("released-username")) {
		t.Fatal("DeriveKey not a stable 32-byte value")
	}
	if bytes.Equal(a, k1.DeriveKey("other")) || bytes.Equal(a, k2.DeriveKey("released-username")) {
		t.Fatal("DeriveKey not separated by label and key")
	}
}
