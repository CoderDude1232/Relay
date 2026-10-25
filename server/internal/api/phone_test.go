package api

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/oprf"
)

// stubSMS accepts one fixed code for any number it was asked to text.
type stubSMS struct {
	sent map[string]bool
	code string
}

func (s *stubSMS) Start(_ context.Context, phone string) error {
	s.sent[phone] = true
	return nil
}

func (s *stubSMS) Check(_ context.Context, phone, code string) (bool, error) {
	return s.sent[phone] && code == s.code, nil
}

func TestPhoneNumberRules(t *testing.T) {
	p := &phoneVerification{allowedPrefixes: []string{"+61", "+64"}}
	for _, ok := range []string{"+61412345678", "+6421345678"} {
		if !p.allowedNumber(ok) {
			t.Errorf("rejected %q", ok)
		}
	}
	for _, bad := range []string{"0412345678", "+1 415 555 0100", "+14155550100", "+61", "+610", "61412345678", "+61412345678x"} {
		if p.allowedNumber(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
	capped := &phoneVerification{dailyCap: 2}
	now := timeNowForTest()
	if !capped.takeDailySlot(now) || !capped.takeDailySlot(now) || capped.takeDailySlot(now) {
		t.Fatal("daily cap not enforced")
	}
	capped.refundDailySlot()
	if !capped.takeDailySlot(now) {
		t.Fatal("refund didn't free a slot")
	}
}

func TestPhoneVerificationFlow(t *testing.T) {
	env := newTestEnv(t)
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	sms := &stubSMS{sent: map[string]bool{}, code: "123456"}
	env.api.SetPhoneVerification(sms, []string{"+61"}, 10)

	alice := env.registerAs(uniqueUsername("phonea"), "password123")
	bob := env.registerAs(uniqueUsername("phoneb"), "password123")
	const number = "+61400000001"

	var status struct {
		HasPhone     bool `json:"hasPhone"`
		Discoverable bool `json:"discoverable"`
		Available    bool `json:"available"`
	}
	env.doJSON("GET", "/v1/accounts/me/phone", alice.authUser(), alice.password, nil, http.StatusOK, &status)
	if status.HasPhone || !status.Available {
		t.Fatalf("initial status = %+v", status)
	}

	// Format and country checks happen before anything is texted.
	env.doJSON("POST", "/v1/accounts/me/phone/start", alice.authUser(), alice.password, map[string]string{"phone": "0400000001"}, http.StatusBadRequest, nil)
	env.doJSON("POST", "/v1/accounts/me/phone/start", alice.authUser(), alice.password, map[string]string{"phone": "+14155550100"}, http.StatusUnprocessableEntity, nil)
	if len(sms.sent) != 0 {
		t.Fatalf("texted before the checks passed: %v", sms.sent)
	}

	env.doJSON("POST", "/v1/accounts/me/phone/start", alice.authUser(), alice.password, map[string]string{"phone": number}, http.StatusNoContent, nil)
	verify := func(c *client, code string, want int) {
		t.Helper()
		env.doJSON("POST", "/v1/accounts/me/phone/verify", c.authUser(), c.password,
			map[string]any{"phone": number, "code": code, "discoverable": true}, want, nil)
	}
	verify(alice, "000000", http.StatusUnauthorized)
	verify(alice, "123456", http.StatusNoContent)
	env.doJSON("GET", "/v1/accounts/me/phone", alice.authUser(), alice.password, nil, http.StatusOK, &status)
	if !status.HasPhone || !status.Discoverable {
		t.Fatalf("after verify = %+v", status)
	}

	// The number moves to whoever verifies it next.
	env.doJSON("POST", "/v1/accounts/me/phone/start", bob.authUser(), bob.password, map[string]string{"phone": number}, http.StatusNoContent, nil)
	verify(bob, "123456", http.StatusNoContent)
	env.doJSON("GET", "/v1/accounts/me/phone", alice.authUser(), alice.password, nil, http.StatusOK, &status)
	if status.HasPhone {
		t.Fatal("number still on the previous account")
	}

	// Discoverability can be turned off, then the number removed.
	env.doJSON("PUT", "/v1/accounts/me/phone/discoverability", bob.authUser(), bob.password, map[string]bool{"discoverable": false}, http.StatusNoContent, nil)
	env.doJSON("GET", "/v1/accounts/me/phone", bob.authUser(), bob.password, nil, http.StatusOK, &status)
	if !status.HasPhone || status.Discoverable {
		t.Fatalf("after discoverability off = %+v", status)
	}
	env.doJSON("DELETE", "/v1/accounts/me/phone", bob.authUser(), bob.password, nil, http.StatusNoContent, nil)
	env.doJSON("GET", "/v1/accounts/me/phone", bob.authUser(), bob.password, nil, http.StatusOK, &status)
	if status.HasPhone {
		t.Fatal("number not removed")
	}
	// No number: discoverability has nothing to change.
	env.doJSON("PUT", "/v1/accounts/me/phone/discoverability", bob.authUser(), bob.password, map[string]bool{"discoverable": true}, http.StatusNotFound, nil)
}

func timeNowForTest() time.Time { return time.Now() }
