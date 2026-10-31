// Package supporter turns a Relay Supporter subscription into perks without
// linking the payment to an account.
//
// Issuance (unauthenticated): the app sends the App Store's signed
// transaction plus blinded elements B = r·H(period, nonce), one per period
// the subscription covers. The relay verifies the transaction, answers each
// with E = k_p·B and a DLEQ proof that it used the published key
// Y_p = k_p·G, and records the transaction so it can't be reused.
//
// Redemption (authenticated): the app unblinds N = r⁻¹·E and presents
// (period, nonce, N). The relay checks N = k_p·H(period, nonce), marks the
// nonce spent and makes the account a supporter until the period ends. It
// has never seen nonce or N before, so it can't tell which transaction paid.
//
// This is the Privacy Pass VOPRF construction (RFC 9497/9578) over
// ristretto255 with Relay's own domain tags. The app's half is
// Relay/SupporterCredential.swift and must match byte-for-byte.
package supporter

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gtank/ristretto255"
)

const (
	keyDomain   = "Relay-Supporter-v1-key:"
	h2gDomain   = "Relay-Supporter-v1-h2g"
	dleqDomain  = "Relay-Supporter-v1-dleq"
	NonceLength = 32
	// MaxPeriods caps the periods one transaction is issued for: the one it
	// starts in and the one it renews in.
	MaxPeriods = 2
)

// Periods: "m2026-11" is a UTC calendar month (production);
// "h2026-11-01T13" a UTC hour, for sandbox purchases, which renew every few
// minutes. A credential grants supporter status until its period ends.

// PeriodAt is the period containing t.
func PeriodAt(t time.Time, sandbox bool) string {
	t = t.UTC()
	if sandbox {
		return "h" + t.Format("2006-01-02T15")
	}
	return "m" + t.Format("2006-01")
}

// ParsePeriod returns a period's bounds.
func ParsePeriod(p string) (start, end time.Time, sandbox bool, err error) {
	switch {
	case strings.HasPrefix(p, "m"):
		start, err = time.Parse("2006-01", p[1:])
		end = start.AddDate(0, 1, 0)
	case strings.HasPrefix(p, "h"):
		start, err = time.Parse("2006-01-02T15", p[1:])
		end, sandbox = start.Add(time.Hour), true
	default:
		err = errors.New("supporter: bad period")
	}
	if err == nil && PeriodAt(start, sandbox) != p {
		err = errors.New("supporter: non-canonical period")
	}
	return start, end, sandbox, err
}

// PeriodsFor lists the periods from now until the transaction expires
// (at most MaxPeriods).
func PeriodsFor(tx *Transaction, now time.Time) []string {
	var out []string
	for t := now; t.Before(tx.Expires()) && len(out) < MaxPeriods; {
		p := PeriodAt(t, tx.Sandbox())
		out = append(out, p)
		_, end, _, _ := ParsePeriod(p)
		t = end
	}
	return out
}

// Issuer holds the master secret; each period's key is derived from it.
type Issuer struct {
	master []byte
}

// LoadOrCreateIssuer reads a hex 32-byte master secret from path, creating
// one (0600) if missing. Losing it only invalidates unredeemed credentials.
func LoadOrCreateIssuer(path string) (*Issuer, error) {
	data, err := os.ReadFile(path)
	if err == nil {
		raw, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(raw) != 32 {
			return nil, errors.New("supporter: bad key file")
		}
		return &Issuer{master: raw}, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("supporter: read key file: %w", err)
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, []byte(hex.EncodeToString(raw)), 0o600); err != nil {
		return nil, fmt.Errorf("supporter: persist key: %w", err)
	}
	return &Issuer{master: raw}, nil
}

// NewIssuer is for tests.
func NewIssuer(master []byte) *Issuer { return &Issuer{master: master} }

func (is *Issuer) key(period string) *ristretto255.Scalar {
	m := hmac.New(sha512.New, is.master)
	m.Write([]byte(keyDomain + period))
	return ristretto255.NewScalar().FromUniformBytes(m.Sum(nil))
}

// PublicKey is Y_p = k_p·G, which the app checks proofs against.
func (is *Issuer) PublicKey(period string) []byte {
	return ristretto255.NewElement().ScalarBaseMult(is.key(period)).Encode(nil)
}

// HashToGroup is H(period, nonce).
func HashToGroup(period string, nonce []byte) *ristretto255.Element {
	h := sha512.New()
	h.Write([]byte(h2gDomain))
	h.Write([]byte(period))
	h.Write([]byte{0})
	h.Write(nonce)
	return ristretto255.NewElement().FromUniformBytes(h.Sum(nil))
}

func challenge(y, b, e, a1, a2 *ristretto255.Element) *ristretto255.Scalar {
	h := sha512.New()
	h.Write([]byte(dleqDomain))
	for _, p := range []*ristretto255.Element{y, b, e, a1, a2} {
		h.Write(p.Encode(nil))
	}
	return ristretto255.NewScalar().FromUniformBytes(h.Sum(nil))
}

func decodePoint(raw []byte) (*ristretto255.Element, error) {
	p := ristretto255.NewElement()
	if len(raw) != 32 || p.Decode(raw) != nil || p.Equal(ristretto255.NewIdentityElement()) == 1 {
		return nil, errors.New("supporter: bad point")
	}
	return p, nil
}

func randomScalar() *ristretto255.Scalar {
	var b [64]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("supporter: crypto/rand failed: " + err.Error())
	}
	return ristretto255.NewScalar().FromUniformBytes(b[:])
}

// Evaluate signs one blinded element for a period: E = k_p·B, with proof
// c ‖ s (64 bytes) that log_G(Y_p) = log_B(E).
func (is *Issuer) Evaluate(period string, blinded []byte) (evaluated, proof []byte, err error) {
	b, err := decodePoint(blinded)
	if err != nil {
		return nil, nil, err
	}
	k := is.key(period)
	y := ristretto255.NewElement().ScalarBaseMult(k)
	e := ristretto255.NewElement().ScalarMult(k, b)
	r := randomScalar()
	a1 := ristretto255.NewElement().ScalarBaseMult(r)
	a2 := ristretto255.NewElement().ScalarMult(r, b)
	c := challenge(y, b, e, a1, a2)
	s := ristretto255.NewScalar().Subtract(r, ristretto255.NewScalar().Multiply(c, k))
	return e.Encode(nil), append(c.Encode(nil), s.Encode(nil)...), nil
}

// VerifyProof is the app's check of Evaluate (here for tests).
func VerifyProof(publicKey, blinded, evaluated, proof []byte) bool {
	y, err1 := decodePoint(publicKey)
	b, err2 := decodePoint(blinded)
	e, err3 := decodePoint(evaluated)
	if err1 != nil || err2 != nil || err3 != nil || len(proof) != 64 {
		return false
	}
	c, s := ristretto255.NewScalar(), ristretto255.NewScalar()
	if c.Decode(proof[:32]) != nil || s.Decode(proof[32:]) != nil {
		return false
	}
	a1 := ristretto255.NewElement().Add(
		ristretto255.NewElement().ScalarBaseMult(s), ristretto255.NewElement().ScalarMult(c, y))
	a2 := ristretto255.NewElement().Add(
		ristretto255.NewElement().ScalarMult(s, b), ristretto255.NewElement().ScalarMult(c, e))
	return challenge(y, b, e, a1, a2).Equal(c) == 1
}

// Check verifies a redeemed credential: point = k_p·H(period, nonce).
func (is *Issuer) Check(period string, nonce, point []byte) bool {
	n, err := decodePoint(point)
	if err != nil || len(nonce) != NonceLength {
		return false
	}
	want := ristretto255.NewElement().ScalarMult(is.key(period), HashToGroup(period, nonce))
	return want.Equal(n) == 1
}

// TransactionTag keys a transaction id so the issuance table holds no App
// Store ids.
func (is *Issuer) TransactionTag(transactionID string) []byte {
	m := hmac.New(sha512.New, is.master)
	m.Write([]byte("Relay-Supporter-v1-tx:" + transactionID))
	return m.Sum(nil)[:32]
}

// NonceTag keys a redeemed nonce for the spent table.
func (is *Issuer) NonceTag(period string, nonce []byte) []byte {
	m := hmac.New(sha512.New, is.master)
	m.Write([]byte("Relay-Supporter-v1-spent:" + period + "\x00"))
	m.Write(nonce)
	return m.Sum(nil)[:32]
}
