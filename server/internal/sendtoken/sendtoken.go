// Package sendtoken issues and checks anonymous send tokens: what the relay
// rate-limits sealed sends, sealed key fetches and call rings by instead of
// the sender's IP address.
//
// A signed-in device asks for a batch for the current UTC day (blinded, so
// the relay can't recognise them later) and spends one per anonymous request.
// The relay checks it against its one long-lived key, whose public half is
// built into the app: a key served per user could tag who spends which token,
// and a key the app never fetches can't be. Tokens are good on the day they
// were issued for and the day after, and each works once.
package sendtoken

import (
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gtank/ristretto255"

	"github.com/relayapp/relay-server/internal/voprf"
)

const (
	keyDomain   = "Relay-SendToken-v1-key"
	NonceLength = 32
)

var suite = voprf.Suite{H2G: "Relay-SendToken-v1-h2g", DLEQ: "Relay-SendToken-v1-dleq"}

var (
	ErrMalformed = errors.New("sendtoken: malformed token")
	ErrExpired   = errors.New("sendtoken: token for another day")
	ErrInvalid   = errors.New("sendtoken: token doesn't verify")
	ErrSpent     = errors.New("sendtoken: token already used")
)

// Day is the UTC day number of t, the label tokens are issued under.
func Day(t time.Time) int64 { return t.Unix() / 86400 }

// Issuer holds the key and the tokens spent today and yesterday (in memory:
// a restart forgets them, which at worst lets tokens already issued be used
// twice).
type Issuer struct {
	k *ristretto255.Scalar

	mu    sync.Mutex
	spent map[[NonceLength]byte]int64 // nonce → day
	now   func() time.Time
}

// LoadOrCreateIssuer reads a hex 32-byte seed from path, creating one (0600)
// if missing. The app builds in the public half, so the file must never be
// replaced or lost.
func LoadOrCreateIssuer(path string) (*Issuer, error) {
	data, err := os.ReadFile(path)
	if err == nil {
		raw, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(raw) != 32 {
			return nil, errors.New("sendtoken: bad key file")
		}
		return NewIssuer(raw), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("sendtoken: read key file: %w", err)
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, []byte(hex.EncodeToString(raw)), 0o600); err != nil {
		return nil, fmt.Errorf("sendtoken: persist key: %w", err)
	}
	return NewIssuer(raw), nil
}

// NewIssuer derives the key from a 32-byte seed.
func NewIssuer(seed []byte) *Issuer {
	h := sha512.New()
	h.Write([]byte(keyDomain))
	h.Write(seed)
	return &Issuer{
		k:     ristretto255.NewScalar().FromUniformBytes(h.Sum(nil)),
		spent: map[[NonceLength]byte]int64{},
		now:   time.Now,
	}
}

// PublicKey is Y = k·G, built into the app.
func (is *Issuer) PublicKey() []byte { return voprf.PublicKey(is.k) }

// Today is the day tokens are issued for now.
func (is *Issuer) Today() int64 { return Day(is.now()) }

// Evaluate answers one blinded element B = r·H(day, nonce) with E = k·B and
// its proof. The day is bound by the client's hash, not checked here: a
// token blinded for another day just won't spend.
func (is *Issuer) Evaluate(blinded []byte) (evaluated, proof []byte, err error) {
	return suite.Evaluate(is.k, blinded)
}

func label(day int64) string { return strconv.FormatInt(day, 10) }

// Parse splits a Relay-Token header value: "<day>.<base64url(nonce ‖ point)>".
func Parse(v string) (day int64, nonce, point []byte, err error) {
	d, rest, ok := strings.Cut(v, ".")
	if !ok {
		return 0, nil, nil, ErrMalformed
	}
	day, err = strconv.ParseInt(d, 10, 64)
	raw, err2 := base64.RawURLEncoding.DecodeString(rest)
	if err != nil || err2 != nil || len(raw) != NonceLength+32 {
		return 0, nil, nil, ErrMalformed
	}
	return day, raw[:NonceLength], raw[NonceLength:], nil
}

// Format is Parse's inverse.
func Format(day int64, nonce, point []byte) string {
	return label(day) + "." + base64.RawURLEncoding.EncodeToString(append(append([]byte{}, nonce...), point...))
}

// Spend checks a token and marks it used.
func (is *Issuer) Spend(header string) error {
	day, nonce, point, err := Parse(header)
	if err != nil {
		return err
	}
	today := is.Today()
	if day != today && day != today-1 {
		return ErrExpired
	}
	if !suite.Check(is.k, label(day), nonce, point) {
		return ErrInvalid
	}
	var n [NonceLength]byte
	copy(n[:], nonce)
	is.mu.Lock()
	defer is.mu.Unlock()
	for k, d := range is.spent {
		if d < today-1 {
			delete(is.spent, k)
		}
	}
	if _, used := is.spent[n]; used {
		return ErrSpent
	}
	is.spent[n] = day
	return nil
}

// Blind is the client's half, for tests and the interop vector: B =
// r·H(day, nonce).
func Blind(day int64, nonce []byte, r *ristretto255.Scalar) []byte {
	return ristretto255.NewElement().ScalarMult(r, suite.HashToGroup(label(day), nonce)).Encode(nil)
}

// Finish checks the proof and unblinds N = r⁻¹·E (for tests).
func Finish(publicKey, blinded, evaluated, proof []byte, r *ristretto255.Scalar) ([]byte, bool) {
	if !suite.VerifyProof(publicKey, blinded, evaluated, proof) {
		return nil, false
	}
	e, err := voprf.DecodePoint(evaluated)
	if err != nil {
		return nil, false
	}
	rInv := ristretto255.NewScalar().Invert(r)
	return ristretto255.NewElement().ScalarMult(rInv, e).Encode(nil), true
}
