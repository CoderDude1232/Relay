package api

import (
	"bytes"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gtank/ristretto255"
	"github.com/relayapp/relay-server/internal/pinguard"
	"github.com/relayapp/relay-server/internal/store"
)

// TestPinGuardRequestValidation: malformed requests are refused before any
// store access. No database.
func TestPinGuardRequestValidation(t *testing.T) {
	for _, l := range allLimiters {
		l.reset()
	}
	s := New(nil, nil, nil, "", "")
	dev := &store.Device{AccountID: "acct", DeviceID: 1}
	short := base64.StdEncoding.EncodeToString(make([]byte, 31))
	for _, tc := range []struct {
		name string
		h    func(http.ResponseWriter, *http.Request, *store.Device)
		body string
	}{
		{"enrol: not JSON", s.handleEnrolPinGuard, `x`},
		{"enrol: missing", s.handleEnrolPinGuard, `{}`},
		{"enrol: short", s.handleEnrolPinGuard, `{"blinded":"` + short + `"}`},
		{"enrol: not base64", s.handleEnrolPinGuard, `{"blinded":"!!!"}`},
		{"evaluate: short", s.handleEvaluatePinGuard, `{"blinded":"` + short + `"}`},
		{"verifier: short", s.handleSetPinGuardVerifier, `{"verifier":"` + short + `"}`},
		{"confirm: short", s.handleConfirmPinGuard, `{"verifier":"` + short + `"}`},
		{"confirm: missing", s.handleConfirmPinGuard, `{}`},
	} {
		rec := httptest.NewRecorder()
		tc.h(rec, httptest.NewRequest("POST", "/", strings.NewReader(tc.body)), dev)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", tc.name, rec.Code)
		}
	}
}

// pinClient plays the device's side of the OPRF.
type pinClient struct {
	t *testing.T
	r *ristretto255.Scalar
}

func (p *pinClient) blind(pin string) string {
	var b [64]byte
	rand.Read(b[:])
	p.r = ristretto255.NewScalar().FromUniformBytes(b[:])
	h := sha512.Sum512([]byte("test|" + pin))
	point := ristretto255.NewElement().FromUniformBytes(h[:])
	return base64.StdEncoding.EncodeToString(ristretto255.NewElement().ScalarMult(p.r, point).Encode(nil))
}

func (p *pinClient) unblind(evaluated string) []byte {
	raw, err := base64.StdEncoding.DecodeString(evaluated)
	if err != nil {
		p.t.Fatal(err)
	}
	e := ristretto255.NewElement()
	if err := e.Decode(raw); err != nil {
		p.t.Fatal(err)
	}
	return ristretto255.NewElement().ScalarMult(ristretto255.NewScalar().Invert(p.r), e).Encode(nil)
}

// verifierFor stands in for the device's tag (which also mixes in a secret
// that never leaves the phone): any 32 bytes derived from the output.
func verifierFor(output []byte) string {
	h := sha512.Sum512(append([]byte("verify|"), output...))
	return base64.StdEncoding.EncodeToString(h[:pinguard.VerifierSize])
}

func TestPinGuardFlow(t *testing.T) {
	env := newTestEnv(t)
	c := env.register("pinguard", "correct horse battery")
	other := env.register("pinguard2", "correct horse battery")
	p := &pinClient{t: t}
	type evalResp struct {
		Evaluated    string `json:"evaluated"`
		AttemptsLeft int    `json:"attemptsLeft"`
	}

	// Nothing to evaluate before enrolment.
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusNotFound, nil)

	var enrol evalResp
	env.doJSON("POST", "/v1/devices/me/pin-guard", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusOK, &enrol)
	enrolled := p.unblind(enrol.Evaluated)
	// A retry before the verifier is set answers with the same key.
	env.doJSON("POST", "/v1/devices/me/pin-guard", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusOK, &enrol)
	if !bytes.Equal(p.unblind(enrol.Evaluated), enrolled) {
		t.Fatal("enrolment retry used a different key")
	}
	// Unfinished enrolments can't be evaluated against.
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusNotFound, nil)

	env.doJSON("PUT", "/v1/devices/me/pin-guard/verifier", c.authUser(), "", map[string]string{"verifier": verifierFor(enrolled)}, http.StatusNoContent, nil)
	env.doJSON("PUT", "/v1/devices/me/pin-guard/verifier", c.authUser(), "", map[string]string{"verifier": verifierFor(enrolled)}, http.StatusConflict, nil)
	// Another account's device has no key, and can't touch this one.
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", other.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusNotFound, nil)

	// The right PIN gives the enrolment output; confirming resets the count.
	var ev evalResp
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusOK, &ev)
	if out := p.unblind(ev.Evaluated); !bytes.Equal(out, enrolled) {
		t.Fatal("right PIN, different output")
	}
	if ev.AttemptsLeft != pinguard.MaxAttempts-1 {
		t.Fatalf("attemptsLeft = %d", ev.AttemptsLeft)
	}
	env.doJSON("POST", "/v1/devices/me/pin-guard/confirm", c.authUser(), "", map[string]string{"verifier": verifierFor(enrolled)}, http.StatusNoContent, nil)

	// Wrong PINs: each one counts, and a wrong verifier doesn't reset.
	for i := 1; i < pinguard.MaxAttempts; i++ {
		env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind(fmt.Sprintf("%06d", i))}, http.StatusOK, &ev)
		if ev.AttemptsLeft != pinguard.MaxAttempts-i {
			t.Fatalf("after %d wrong: attemptsLeft = %d", i, ev.AttemptsLeft)
		}
		env.doJSON("POST", "/v1/devices/me/pin-guard/confirm", c.authUser(), "", map[string]string{"verifier": verifierFor(p.unblind(ev.Evaluated))}, http.StatusForbidden, nil)
	}
	// The last attempt still answers (here with the right PIN)…
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusOK, &ev)
	if ev.AttemptsLeft != 0 {
		t.Fatalf("last attempt: attemptsLeft = %d", ev.AttemptsLeft)
	}
	// …and confirming it resets the count, so it's usable again.
	env.doJSON("POST", "/v1/devices/me/pin-guard/confirm", c.authUser(), "", map[string]string{"verifier": verifierFor(enrolled)}, http.StatusNoContent, nil)
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusOK, &ev)
	if ev.AttemptsLeft != pinguard.MaxAttempts-1 {
		t.Fatalf("after reset: attemptsLeft = %d", ev.AttemptsLeft)
	}

	// Run out: the key is deleted and stays gone.
	for i := 2; i <= pinguard.MaxAttempts; i++ {
		env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("000000")}, http.StatusOK, nil)
	}
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusGone, nil)
	env.doJSON("POST", "/v1/devices/me/pin-guard/evaluate", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusNotFound, nil)
	env.doJSON("POST", "/v1/devices/me/pin-guard/confirm", c.authUser(), "", map[string]string{"verifier": verifierFor(enrolled)}, http.StatusNotFound, nil)

	// Enrolling again makes a new key; DELETE removes it.
	env.doJSON("POST", "/v1/devices/me/pin-guard", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusOK, &enrol)
	if bytes.Equal(p.unblind(enrol.Evaluated), enrolled) {
		t.Fatal("re-enrolment reused the deleted key")
	}
	env.doJSON("DELETE", "/v1/devices/me/pin-guard", c.authUser(), "", nil, http.StatusNoContent, nil)
	env.doJSON("DELETE", "/v1/devices/me/pin-guard", c.authUser(), "", nil, http.StatusNoContent, nil)
	env.doJSON("PUT", "/v1/devices/me/pin-guard/verifier", c.authUser(), "", map[string]string{"verifier": verifierFor(enrolled)}, http.StatusNotFound, nil)

	// The row goes with its device when the account is deleted.
	env.doJSON("POST", "/v1/devices/me/pin-guard", c.authUser(), "", map[string]string{"blinded": p.blind("123456")}, http.StatusOK, nil)
	if _, err := env.api.store.DeleteAccount(c.accountID); err != nil {
		t.Fatal(err)
	}
	if _, err := env.api.store.PinGuardEnrolmentScalar(c.accountID, c.deviceID); err != store.ErrNotFound {
		t.Fatalf("after account deletion: %v", err)
	}
}
