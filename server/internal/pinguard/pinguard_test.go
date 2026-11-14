package pinguard

import (
	"bytes"
	"crypto/rand"
	"crypto/sha512"
	"errors"
	"testing"

	"github.com/gtank/ristretto255"
)

func randomScalar(t *testing.T) *ristretto255.Scalar {
	t.Helper()
	var b [64]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	return ristretto255.NewScalar().FromUniformBytes(b[:])
}

func hashToGroup(pin string) *ristretto255.Element {
	h := sha512.Sum512([]byte("test|" + pin))
	return ristretto255.NewElement().FromUniformBytes(h[:])
}

// The unblinded output depends only on the PIN and the device's key, never on
// the blinding, so the same PIN always opens the same data.
func TestBlindedEvaluationIsDeterministic(t *testing.T) {
	k, err := NewScalar()
	if err != nil {
		t.Fatal(err)
	}
	output := func(pin string) []byte {
		r := randomScalar(t)
		blinded := ristretto255.NewElement().ScalarMult(r, hashToGroup(pin)).Encode(nil)
		evaluated, err := Evaluate(k, blinded)
		if err != nil {
			t.Fatal(err)
		}
		e := ristretto255.NewElement()
		if err := e.Decode(evaluated); err != nil {
			t.Fatal(err)
		}
		return ristretto255.NewElement().ScalarMult(ristretto255.NewScalar().Invert(r), e).Encode(nil)
	}
	a, b := output("123456"), output("123456")
	if !bytes.Equal(a, b) {
		t.Fatal("same PIN, different outputs")
	}
	if bytes.Equal(a, output("123457")) {
		t.Fatal("different PINs, same output")
	}
	k2, _ := NewScalar()
	r := randomScalar(t)
	blinded := ristretto255.NewElement().ScalarMult(r, hashToGroup("123456")).Encode(nil)
	other, _ := Evaluate(k2, blinded)
	same, _ := Evaluate(k, blinded)
	if bytes.Equal(other, same) {
		t.Fatal("different device keys, same evaluation")
	}
}

func TestEvaluateRejectsBadElements(t *testing.T) {
	k, _ := NewScalar()
	for name, in := range map[string][]byte{
		"empty":    nil,
		"short":    make([]byte, 31),
		"identity": ristretto255.NewElement().Zero().Encode(nil),
		"garbage":  bytes.Repeat([]byte{0xff}, 32),
	} {
		if _, err := Evaluate(k, in); !errors.Is(err, ErrBadElement) {
			t.Errorf("%s: got %v, want ErrBadElement", name, err)
		}
	}
}
