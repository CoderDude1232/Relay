package oprf

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"fmt"
	"os"
	"testing"

	"github.com/gtank/ristretto255"
)

// clientDeriveToken simulates exactly what the iOS client does with libsodium:
// blind H1(x) with a random scalar, hand the blinded point to the server for
// evaluation, unblind, then derive the token. It must equal Key.Token(x).
func clientDeriveToken(t *testing.T, k *Key, identifier string) []byte {
	t.Helper()
	x := []byte(Normalize(identifier))

	// H1(x)
	h := sha512.New()
	h.Write([]byte(hashToGroupDomain))
	h.Write(x)
	hx := ristretto255.NewElement().FromUniformBytes(h.Sum(nil))

	// random blinding scalar r
	var rb [64]byte
	if _, err := rand.Read(rb[:]); err != nil {
		t.Fatal(err)
	}
	r := ristretto255.NewScalar().FromUniformBytes(rb[:])

	// B = r·H1(x)
	blinded := ristretto255.NewElement().ScalarMult(r, hx).Encode(nil)

	// server: E = k·B
	evaluated, err := k.Evaluate(blinded)
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	e := ristretto255.NewElement()
	if err := e.Decode(evaluated); err != nil {
		t.Fatalf("decode evaluated: %v", err)
	}

	// unblind: N = r⁻¹·E
	rInv := ristretto255.NewScalar().Invert(r)
	n := ristretto255.NewElement().ScalarMult(rInv, e)

	// token = H2(x, N)
	th := sha256.New()
	th.Write([]byte(tokenDomain))
	th.Write(x)
	th.Write(n.Encode(nil))
	return th.Sum(nil)
}

func TestOPRFRoundTrip(t *testing.T) {
	k, err := Generate()
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"alice", "Bob@Example.com ", "  Carol", "dave123"} {
		server := k.Token(id)
		client := clientDeriveToken(t, k, id)
		if !bytes.Equal(server, client) {
			t.Fatalf("token mismatch for %q:\n server=%x\n client=%x", id, server, client)
		}
	}
}

func TestOPRFNormalizationMatches(t *testing.T) {
	k, _ := Generate()
	if !bytes.Equal(k.Token("Alice"), k.Token("  alice ")) {
		t.Fatal("normalization should make case/whitespace variants collide")
	}
	if bytes.Equal(k.Token("alice"), k.Token("alicia")) {
		t.Fatal("distinct identifiers must produce distinct tokens")
	}
}

func TestOPRFDistinctKeys(t *testing.T) {
	k1, _ := Generate()
	k2, _ := Generate()
	if bytes.Equal(k1.Token("alice"), k2.Token("alice")) {
		t.Fatal("different keys must produce different tokens")
	}
}

func TestLoadOrCreateKeyPersists(t *testing.T) {
	path := t.TempDir() + "/oprf.key"
	k1, err := LoadOrCreateKey(path)
	if err != nil {
		t.Fatal(err)
	}
	k2, err := LoadOrCreateKey(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(k1.Token("alice"), k2.Token("alice")) {
		t.Fatal("reloaded key should produce identical tokens")
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("key file perms: %v %v", fi.Mode().Perm(), err)
	}
}

// TestPrintInteropVector emits a fixed vector (set PRINT_OPRF_VECTOR=1) so the
// Swift OPRF client can be checked against this exact key/identifier.
func TestPrintInteropVector(t *testing.T) {
	if os.Getenv("PRINT_OPRF_VECTOR") == "" {
		t.Skip("set PRINT_OPRF_VECTOR=1 to print an interop vector")
	}
	k, _ := Generate()
	id := "alice"
	fmt.Println("keyHex   =", fmt.Sprintf("%x", k.scalar.Encode(nil)))
	fmt.Println("identifier =", id)
	fmt.Println("tokenB64 =", base64.StdEncoding.EncodeToString(k.Token(id)))
}
