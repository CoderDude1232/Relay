package supporter

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/gtank/ristretto255"
	"github.com/relayapp/relay-server/internal/supporter/supportertest"
)

func blind(period string, nonce []byte) (r *ristretto255.Scalar, b []byte) {
	r = randomScalar()
	return r, ristretto255.NewElement().ScalarMult(r, HashToGroup(period, nonce)).Encode(nil)
}

func unblind(r *ristretto255.Scalar, evaluated []byte) []byte {
	e, _ := decodePoint(evaluated)
	return ristretto255.NewElement().ScalarMult(ristretto255.NewScalar().Invert(r), e).Encode(nil)
}

func TestCredentialRoundTrip(t *testing.T) {
	is := NewIssuer(bytes.Repeat([]byte{7}, 32))
	period := "m2026-11"
	nonce := bytes.Repeat([]byte{1}, NonceLength)
	r, b := blind(period, nonce)
	e, proof, err := is.Evaluate(period, b)
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyProof(is.PublicKey(period), b, e, proof) {
		t.Fatal("proof doesn't verify")
	}
	if VerifyProof(is.PublicKey("m2026-12"), b, e, proof) {
		t.Fatal("proof verifies under another period's key")
	}
	n := unblind(r, e)
	if !is.Check(period, nonce, n) {
		t.Fatal("credential doesn't check")
	}
	if is.Check("m2026-12", nonce, n) {
		t.Fatal("credential checks for another period")
	}
	if is.Check(period, bytes.Repeat([]byte{2}, NonceLength), n) {
		t.Fatal("credential checks for another nonce")
	}
	if NewIssuer(bytes.Repeat([]byte{8}, 32)).Check(period, nonce, n) {
		t.Fatal("credential checks under another master key")
	}
	if _, _, err := is.Evaluate(period, make([]byte, 32)); err == nil {
		t.Fatal("identity element accepted")
	}
}

// Fixed values the Swift client's interop test checks against
// (RelayTests/SupporterCredentialTests.swift).
func TestInteropVector(t *testing.T) {
	is := NewIssuer(bytes.Repeat([]byte{7}, 32))
	period := "m2026-11"
	nonce := bytes.Repeat([]byte{1}, NonceLength)
	var rb [64]byte
	rb[0] = 3
	r := ristretto255.NewScalar().FromUniformBytes(rb[:])
	b := ristretto255.NewElement().ScalarMult(r, HashToGroup(period, nonce)).Encode(nil)
	e, _, _ := is.Evaluate(period, b)
	n := unblind(r, e)
	want := map[string]string{
		"publicKey": "58091c6a65c598b62ccf747f1c2a67dad77203249efd2ea7e62b014bbbd1b02c",
		"blinded":   "8a1c2ad4bb18a5dd17670c0a5cf42de2e1970bd8f8d2cb19fba8bc68cf9f9e04",
		"evaluated": "1aeba91ccf1d11508e967605c59829e852d5239959ccf7e51a2ad3d3dacd431e",
		"unblinded": "126f2b4b53dec7aa7e58b61ec226889cb5854b79cf63da84c2e965aa6d681537",
	}
	got := map[string]string{
		"publicKey": hex.EncodeToString(is.PublicKey(period)),
		"blinded":   hex.EncodeToString(b),
		"evaluated": hex.EncodeToString(e),
		"unblinded": hex.EncodeToString(n),
	}
	for k, v := range got {
		if want[k] != v {
			t.Errorf("%s = %s, want %s", k, v, want[k])
		}
		t.Logf("%s %s", k, v)
	}
}

func TestPeriods(t *testing.T) {
	now := time.Date(2026, 11, 20, 10, 30, 0, 0, time.UTC)
	tx := &Transaction{Environment: "Production", ExpiresDate: now.AddDate(0, 1, 0).UnixMilli()}
	if got := PeriodsFor(tx, now); strings.Join(got, ",") != "m2026-11,m2026-12" {
		t.Fatalf("monthly periods = %v", got)
	}
	tx.ExpiresDate = time.Date(2026, 11, 28, 0, 0, 0, 0, time.UTC).UnixMilli()
	if got := PeriodsFor(tx, now); strings.Join(got, ",") != "m2026-11" {
		t.Fatalf("periods = %v", got)
	}
	sb := &Transaction{Environment: "Sandbox", ExpiresDate: now.Add(5 * time.Minute).UnixMilli()}
	if got := PeriodsFor(sb, now); strings.Join(got, ",") != "h2026-11-20T10" {
		t.Fatalf("sandbox periods = %v", got)
	}
	start, end, sandbox, err := ParsePeriod("m2026-12")
	if err != nil || sandbox || !start.Equal(time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)) ||
		!end.Equal(time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("ParsePeriod = %v %v %v %v", start, end, sandbox, err)
	}
	for _, bad := range []string{"", "x2026-11", "m2026-1", "m2026-13", "h2026-11-20T1", "m2026-11 "} {
		if _, _, _, err := ParsePeriod(bad); err == nil {
			t.Errorf("ParsePeriod(%q) accepted", bad)
		}
	}
}

// --- App Store JWS, against a throwaway chain shaped like Apple's ---

func testVerifier(t *testing.T, c *supportertest.Chain, sandbox bool) *AppStoreVerifier {
	v, err := NewAppStoreVerifier("app.relaymsg", []string{"app.relaymsg.supporter.monthly1"}, sandbox)
	if err != nil {
		t.Fatal(err)
	}
	v.TrustRoot(c.Root)
	return v
}

func validPayload(now time.Time) map[string]any { return supportertest.Payload(now, "2000000123") }

func TestAppStoreVerify(t *testing.T) {
	now := time.Now()
	c := supportertest.NewChain(t, true)
	v := testVerifier(t, c, false)
	tx, err := v.Verify(c.Sign(t, validPayload(now)), now)
	if err != nil || tx.TransactionID != "2000000123" {
		t.Fatalf("valid transaction: %v %v", tx, err)
	}

	for name, edit := range map[string]func(map[string]any){
		"bundle":   func(p map[string]any) { p["bundleId"] = "com.other" },
		"product":  func(p map[string]any) { p["productId"] = "app.relaymsg.other" },
		"type":     func(p map[string]any) { p["type"] = "Consumable" },
		"sandbox":  func(p map[string]any) { p["environment"] = "Sandbox" },
		"xcode":    func(p map[string]any) { p["environment"] = "Xcode" },
		"expired":  func(p map[string]any) { p["expiresDate"] = now.Add(-time.Minute).UnixMilli() },
		"revoked":  func(p map[string]any) { p["revocationDate"] = now.UnixMilli() },
		"no tx id": func(p map[string]any) { p["transactionId"] = "" },
	} {
		p := validPayload(now)
		edit(p)
		if _, err := v.Verify(c.Sign(t, p), now); !errors.Is(err, ErrBadTransaction) {
			t.Errorf("%s: accepted (%v)", name, err)
		}
	}

	sb := validPayload(now)
	sb["environment"] = "Sandbox"
	if _, err := testVerifier(t, c, true).Verify(c.Sign(t, sb), now); err != nil {
		t.Errorf("sandbox with AllowSandbox: %v", err)
	}

	// Tampered payload: signature no longer matches.
	jws := c.Sign(t, validPayload(now))
	parts := strings.Split(jws, ".")
	evil := validPayload(now)
	evil["expiresDate"] = now.AddDate(5, 0, 0).UnixMilli()
	ep, _ := json.Marshal(evil)
	if _, err := v.Verify(parts[0]+"."+base64.RawURLEncoding.EncodeToString(ep)+"."+parts[2], now); err == nil {
		t.Error("tampered payload accepted")
	}

	// A chain that doesn't end at the trusted root.
	other := supportertest.NewChain(t, true)
	if _, err := v.Verify(other.Sign(t, validPayload(now)), now); err == nil {
		t.Error("untrusted chain accepted")
	}

	// A chain from the right root without Apple's marker extensions.
	plain := supportertest.NewChain(t, false)
	if _, err := testVerifier(t, plain, false).Verify(plain.Sign(t, validPayload(now)), now); err == nil {
		t.Error("chain without markers accepted")
	}

	// The real embedded Apple root parses.
	if _, err := NewAppStoreVerifier("app.relaymsg", nil, false); err != nil {
		t.Fatal(err)
	}
}
