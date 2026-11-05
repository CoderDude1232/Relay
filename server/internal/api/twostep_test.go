package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/oprf"
)

func TestTOTPCode(t *testing.T) {
	// RFC 6238 appendix B, SHA-1, truncated to 6 digits.
	secret := []byte("12345678901234567890")
	for _, c := range []struct {
		unix int64
		want string
	}{{59, "287082"}, {1111111109, "081804"}, {1234567890, "005924"}, {2000000000, "279037"}} {
		if got := totpCode(secret, c.unix/totpPeriod); got != c.want {
			t.Errorf("t=%d: %s, want %s", c.unix, got, c.want)
		}
	}
	now := time.Unix(1234567890, 0)
	if totpMatch(secret, "005924", now) != 1234567890/totpPeriod {
		t.Fatal("current code refused")
	}
	if totpMatch(secret, totpCode(secret, now.Unix()/totpPeriod-1), now) < 0 {
		t.Fatal("previous step refused (clock drift)")
	}
	if totpMatch(secret, totpCode(secret, now.Unix()/totpPeriod-3), now) >= 0 || totpMatch(secret, "12345", now) >= 0 {
		t.Fatal("stale or short code accepted")
	}
}

// postJSON posts body and decodes the reply whatever its status.
func (e *testEnv) postJSON(path string, body any, out any) int {
	e.t.Helper()
	raw, _ := json.Marshal(body)
	resp, err := http.Post(e.srv.URL+path, "application/json", bytes.NewReader(raw))
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

type twoStepReply struct {
	AccountID string `json:"accountId"`
	DeviceID  uint32 `json:"deviceId"`
	Created   bool   `json:"created"`
	Error     string `json:"error"`
	TwoStep   struct {
		Ticket      string `json:"ticket"`
		Method      string `json:"method"`
		RecoveryKey bool   `json:"recoveryKey"`
	} `json:"twoStep"`
	SignupTicket string `json:"signupTicket"`
}

func twoStepEnv(t *testing.T) *testEnv {
	env := newTestEnv(t)
	recoveryLockout = newFailureLockout()
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	env.api.SetSupabaseAuth("https://stub.supabase.co", "anon")
	env.api.verifySupabaseToken = func(_ context.Context, token string) (supabaseUser, error) {
		id, email, ok := strings.Cut(token, "|")
		if !ok || id == "" {
			return supabaseUser{}, fmt.Errorf("bad stub token")
		}
		return supabaseUser{ID: id, Email: email, EmailConfirmed: true}, nil
	}
	return env
}

// An email sign-in to an account with an authenticator needs a code from it.
func TestTwoStepAuthenticator(t *testing.T) {
	env := twoStepEnv(t)
	sfx := uniqueUsername("")
	token := "totp" + sfx + "|totp" + sfx + "@x.com"
	var first twoStepReply
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": token, "username": "totp" + sfx, "password": "device-pw-123",
	}, http.StatusCreated, &first)
	c := &client{env: env, accountID: first.AccountID, deviceID: first.DeviceID, password: "device-pw-123"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	// Without two-step, the email code alone signs in (and replaces devices).
	var plain twoStepReply
	if code := env.postJSON("/v1/accounts/oauth", map[string]string{"accessToken": token, "password": "device-pw-456"}, &plain); code != http.StatusOK {
		t.Fatalf("plain sign-in %d %q", code, plain.Error)
	}
	c = &client{env: env, accountID: plain.AccountID, deviceID: plain.DeviceID, password: "device-pw-456"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	var setup struct {
		Secret string `json:"secret"`
		URI    string `json:"uri"`
	}
	env.doJSON("POST", "/v1/accounts/me/totp/setup", c.authUser(), c.password, nil, http.StatusOK, &setup)
	u, err := url.Parse(setup.URI)
	if err != nil || u.Scheme != "otpauth" || u.Query().Get("secret") != setup.Secret {
		t.Fatalf("uri %q", setup.URI)
	}
	secret, err := totpBase32.DecodeString(setup.Secret)
	if err != nil {
		t.Fatal(err)
	}
	code := func(offset int64) string { return totpCode(secret, time.Now().Unix()/totpPeriod+offset) }
	env.doJSON("POST", "/v1/accounts/me/totp/confirm", c.authUser(), c.password, map[string]string{"code": "000000"}, http.StatusUnauthorized, nil)
	env.doJSON("POST", "/v1/accounts/me/totp/confirm", c.authUser(), c.password, map[string]string{"code": code(-1)}, http.StatusNoContent, nil)

	var methods struct {
		TwoStep string `json:"twoStep"`
	}
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", c.authUser(), c.password, nil, http.StatusOK, &methods)
	if methods.TwoStep != "totp" {
		t.Fatalf("method %q", methods.TwoStep)
	}

	var locked twoStepReply
	if code := env.postJSON("/v1/accounts/oauth", map[string]string{"accessToken": token, "password": "device-pw-789"}, &locked); code != http.StatusLocked ||
		locked.TwoStep.Method != "totp" || locked.TwoStep.Ticket == "" {
		t.Fatalf("locked sign-in %d %+v", code, locked)
	}
	complete := func(ticket, totp string) (int, twoStepReply) {
		var out twoStepReply
		status := env.postJSON("/v1/accounts/two-step", map[string]string{"ticket": ticket, "password": "device-pw-789", "code": totp}, &out)
		return status, out
	}
	if s, _ := complete(locked.TwoStep.Ticket, "000000"); s != http.StatusUnauthorized {
		t.Fatalf("wrong code: %d", s)
	}
	// The code used to confirm (step -1) can't be used again.
	if s, _ := complete(locked.TwoStep.Ticket, code(-1)); s != http.StatusUnauthorized {
		t.Fatalf("reused code: %d", s)
	}
	s, done := complete(locked.TwoStep.Ticket, code(0))
	if s != http.StatusOK || done.AccountID != first.AccountID {
		t.Fatalf("right code: %d %+v", s, done)
	}
	if s, _ := complete(locked.TwoStep.Ticket, code(1)); s != http.StatusUnauthorized {
		t.Fatalf("ticket reused: %d", s)
	}
	if devs, err := env.api.store.Devices(first.AccountID); err != nil || len(devs) != 1 || devs[0].DeviceID != done.DeviceID {
		t.Fatalf("devices after two-step: %+v %v", devs, err)
	}
}

// The account password is the PIN step: older clients send it inline, new
// ones complete the ticket.
func TestTwoStepPIN(t *testing.T) {
	env := twoStepEnv(t)
	sfx := uniqueUsername("")
	token := "pin" + sfx + "|pin" + sfx + "@x.com"
	var first twoStepReply
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": token, "username": "pin" + sfx, "password": "device-pw-123",
	}, http.StatusCreated, &first)
	c := &client{env: env, accountID: first.AccountID, deviceID: first.DeviceID, password: "device-pw-123"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()
	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPasswordKey": "pin-key-0123456789abcdefghijklmnopqrstuv"}, http.StatusNoContent, nil)
	// Sensitive changes now need the PIN again on this device first.
	env.doJSON("DELETE", "/v1/accounts/me/account-password", c.authUser(), c.password, nil, http.StatusForbidden, nil)
	stepUp(t, c, map[string]string{"accountPasswordKey": "wrong-key-0123456789abcdefghijklmnopqrstu"}, http.StatusUnauthorized)
	stepUp(t, c, map[string]string{"accountPasswordKey": "pin-key-0123456789abcdefghijklmnopqrstuv"}, http.StatusNoContent)
	// It's now the two-step method, so it can't simply be removed.
	env.doJSON("DELETE", "/v1/accounts/me/account-password", c.authUser(), c.password, nil, http.StatusConflict, nil)

	var locked twoStepReply
	if code := env.postJSON("/v1/accounts/oauth", map[string]string{"accessToken": token, "password": "device-pw-456"}, &locked); code != http.StatusLocked || locked.TwoStep.Method != "pin" {
		t.Fatalf("locked %d %+v", code, locked)
	}
	var out twoStepReply
	if s := env.postJSON("/v1/accounts/two-step", map[string]string{"ticket": locked.TwoStep.Ticket, "password": "device-pw-456", "accountPasswordKey": "wrong-key-0123456789abcdefghijklmnopqrstu"}, &out); s != http.StatusUnauthorized {
		t.Fatalf("wrong pin %d", s)
	}
	if s := env.postJSON("/v1/accounts/two-step", map[string]string{"ticket": locked.TwoStep.Ticket, "password": "device-pw-456", "accountPasswordKey": "pin-key-0123456789abcdefghijklmnopqrstuv"}, &out); s != http.StatusOK || out.AccountID != first.AccountID {
		t.Fatalf("right pin %d %+v", s, out)
	}
	// Inline, as older clients do.
	if s := env.postJSON("/v1/accounts/oauth", map[string]string{"accessToken": token, "password": "device-pw-789", "accountPasswordKey": "pin-key-0123456789abcdefghijklmnopqrstuv"}, &out); s != http.StatusOK {
		t.Fatalf("inline pin %d %q", s, out.Error)
	}
	c = &client{env: env, accountID: out.AccountID, deviceID: out.DeviceID, password: "device-pw-789"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	// Turned off (the device just passed the step to sign in, so it isn't
	// asked again): the email code alone works again, and the PIN can go.
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]string{"method": ""}, http.StatusNoContent, nil)
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]string{"method": "passkey"}, http.StatusConflict, nil)
	env.doJSON("DELETE", "/v1/accounts/me/account-password", c.authUser(), c.password, nil, http.StatusNoContent, nil)
	if s := env.postJSON("/v1/accounts/oauth", map[string]string{"accessToken": token, "password": "device-pw-000"}, &out); s != http.StatusOK {
		t.Fatalf("after turning off %d %q", s, out.Error)
	}
}

// stepUp answers a fresh step-up challenge for c with `answer` (plus the
// ticket) and checks the status.
func stepUp(t *testing.T, c *client, answer map[string]string, want int) {
	t.Helper()
	var ch struct {
		Ticket string `json:"ticket"`
		Method string `json:"method"`
	}
	c.env.doJSON("POST", "/v1/accounts/me/two-step/challenge", c.authUser(), c.password, nil, http.StatusOK, &ch)
	if ch.Ticket == "" {
		t.Fatalf("no step-up ticket (method %q)", ch.Method)
	}
	body := map[string]string{"ticket": ch.Ticket}
	for k, v := range answer {
		body[k] = v
	}
	c.env.doJSON("POST", "/v1/accounts/me/two-step/verify", c.authUser(), c.password, body, want, nil)
}

// A device linked or signed in without the second step can't change how the
// account is signed in to until it answers; the recovery key works instead.
func TestStepUp(t *testing.T) {
	env := twoStepEnv(t)
	sfx := uniqueUsername("")
	token := "stepup" + sfx + "|stepup" + sfx + "@x.com"
	var first twoStepReply
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": token, "username": "stepup" + sfx, "password": "device-pw-123",
	}, http.StatusCreated, &first)
	c := &client{env: env, accountID: first.AccountID, deviceID: first.DeviceID, password: "device-pw-123"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	// No second step yet: nothing to answer, nothing blocked.
	var none struct {
		Method string `json:"method"`
	}
	env.doJSON("POST", "/v1/accounts/me/two-step/challenge", c.authUser(), c.password, nil, http.StatusOK, &none)
	if none.Method != "" {
		t.Fatalf("method %q", none.Method)
	}
	recoveryAuth := "recovery-auth-key-0123456789"
	h := sha256.Sum256([]byte(recoveryKeyAuthHashPrefix + recoveryAuth))
	env.doJSON("PUT", "/v1/accounts/me/recovery-key", c.authUser(), c.password, map[string]string{"hash": b64URL(h[:])}, http.StatusNoContent, nil)
	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPasswordKey": "pin-key-0123456789abcdefghijklmnopqrstuv"}, http.StatusNoContent, nil)

	var reply struct {
		Error  string `json:"error"`
		StepUp struct {
			Method string `json:"method"`
		} `json:"stepUp"`
	}
	env.doJSON("DELETE", "/v1/accounts/me/recovery-key", c.authUser(), c.password, nil, http.StatusForbidden, &reply)
	if reply.StepUp.Method != "pin" {
		t.Fatalf("step-up reply %+v", reply)
	}
	// Someone else's recovery key doesn't count.
	env.doJSON("POST", "/v1/accounts/me/two-step/verify", c.authUser(), c.password, map[string]string{"recoveryAuthKey": "not-the-key-0123456789"}, http.StatusUnauthorized, nil)
	env.doJSON("POST", "/v1/accounts/me/two-step/verify", c.authUser(), c.password, map[string]string{"recoveryAuthKey": recoveryAuth}, http.StatusNoContent, nil)
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]string{"method": "pin"}, http.StatusNoContent, nil)
}

// fakeAttest accepts a key whose attestation is "attested" and assertions
// "ok|<client data hash>".
type fakeAttest struct{}

func (fakeAttest) VerifyAttestation(keyID, attestation, _ []byte, _ time.Time) ([]byte, error) {
	if string(attestation) != "attested" {
		return nil, fmt.Errorf("bad attestation")
	}
	return append([]byte("pub-"), keyID...), nil
}

func (fakeAttest) VerifyAssertion(_, assertion, clientDataHash []byte, previous uint32) (uint32, error) {
	if !bytes.Equal(assertion, append([]byte("ok|"), clientDataHash...)) {
		return 0, fmt.Errorf("bad assertion")
	}
	return previous + 1, nil
}

func TestPhoneSignIn(t *testing.T) {
	env := twoStepEnv(t)
	sms := &stubSMS{sent: map[string]bool{}, code: "123456"}
	env.api.SetPhoneVerification(sms, []string{"+61"}, 50)
	env.api.SetAppAttest(fakeAttest{})
	number := fmt.Sprintf("+614%08d", time.Now().UnixNano()%100000000)

	challenge := func() string {
		var out struct {
			Challenge string `json:"challenge"`
		}
		env.doJSON("POST", "/v1/app-attest/challenge", "", "", nil, http.StatusOK, &out)
		return out.Challenge
	}
	keyID := sha256.Sum256([]byte("key-" + number))
	start := func(want int) {
		t.Helper()
		ch := challenge()
		assertion := append([]byte("ok|"), phoneStartClientData(ch, number)...)
		if s := env.postJSON("/v1/phone/start", map[string]string{
			"phone": number, "keyId": b64URL(keyID[:]), "assertion": b64URL(assertion), "challenge": ch,
		}, nil); s != want {
			t.Fatalf("start: %d, want %d", s, want)
		}
	}
	// Not attested yet, then a bad attestation, then a good one.
	start(http.StatusPreconditionFailed)
	if s := env.postJSON("/v1/app-attest/keys", map[string]string{"keyId": b64URL(keyID[:]), "attestation": b64URL([]byte("forged")), "challenge": challenge()}, nil); s != http.StatusForbidden {
		t.Fatalf("forged attestation %d", s)
	}
	env.doJSON("POST", "/v1/app-attest/keys", "", "", map[string]string{"keyId": b64URL(keyID[:]), "attestation": b64URL([]byte("attested")), "challenge": challenge()}, http.StatusNoContent, nil)
	// An assertion over another number is refused.
	ch := challenge()
	if s := env.postJSON("/v1/phone/start", map[string]string{
		"phone": number, "keyId": b64URL(keyID[:]), "assertion": b64URL(append([]byte("ok|"), phoneStartClientData(ch, "+61400000000")...)), "challenge": ch,
	}, nil); s != http.StatusForbidden {
		t.Fatalf("assertion for another number %d", s)
	}
	start(http.StatusNoContent)
	start(http.StatusTooManyRequests) // the resend cooldown

	// A new number: verified, then a username.
	var reply twoStepReply
	if s := env.postJSON("/v1/phone/signin", map[string]string{"phone": number, "code": "000000", "password": "device-pw-123"}, &reply); s != http.StatusUnauthorized {
		t.Fatalf("wrong code %d", s)
	}
	if s := env.postJSON("/v1/phone/signin", map[string]string{"phone": number, "code": "123456", "password": "device-pw-123"}, &reply); s != http.StatusNotFound || reply.SignupTicket == "" {
		t.Fatalf("new number %d %+v", s, reply)
	}
	name := uniqueUsername("tel")
	var created twoStepReply
	if s := env.postJSON("/v1/phone/signup", map[string]any{"signupTicket": reply.SignupTicket, "username": name, "password": "device-pw-123"}, &created); s != http.StatusCreated || !created.Created {
		t.Fatalf("signup %d %+v", s, created)
	}
	if s := env.postJSON("/v1/phone/signup", map[string]any{"signupTicket": reply.SignupTicket, "username": name + "x", "password": "device-pw-123"}, nil); s != http.StatusUnauthorized {
		t.Fatalf("signup ticket reused %d", s)
	}

	// Signing in again replaces the device.
	var again twoStepReply
	if s := env.postJSON("/v1/phone/signin", map[string]string{"phone": number, "code": "123456", "password": "device-pw-456"}, &again); s != http.StatusOK || again.AccountID != created.AccountID {
		t.Fatalf("sign-in %d %+v", s, again)
	}
	c := &client{env: env, accountID: again.AccountID, deviceID: again.DeviceID, password: "device-pw-456"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()
	var methods struct {
		Phone bool `json:"phone"`
	}
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", c.authUser(), c.password, nil, http.StatusOK, &methods)
	if !methods.Phone {
		t.Fatal("phone not listed as a sign-in method")
	}
	// It's the only way in, so it can't be removed.
	env.doJSON("DELETE", "/v1/accounts/me/phone", c.authUser(), c.password, nil, http.StatusConflict, nil)

	// With a PIN, the number alone isn't enough.
	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPasswordKey": "pin-key-0123456789abcdefghijklmnopqrstuv"}, http.StatusNoContent, nil)
	var locked twoStepReply
	if s := env.postJSON("/v1/phone/signin", map[string]string{"phone": number, "code": "123456", "password": "device-pw-789"}, &locked); s != http.StatusLocked || locked.TwoStep.Method != "pin" {
		t.Fatalf("locked %d %+v", s, locked)
	}
}

// Several methods can be on at once; an answer to any of them passes, and
// each can be turned off on its own.
func TestTwoStepSeveralMethods(t *testing.T) {
	env := twoStepEnv(t)
	sfx := uniqueUsername("")
	token := "multi" + sfx + "|multi" + sfx + "@x.com"
	var first twoStepReply
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": token, "username": "multi" + sfx, "password": "device-pw-123",
	}, http.StatusCreated, &first)
	c := &client{env: env, accountID: first.AccountID, deviceID: first.DeviceID, password: "device-pw-123"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()
	const pin = "pin-key-0123456789abcdefghijklmnopqrstuv"
	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPasswordKey": pin}, http.StatusNoContent, nil)

	// Add the authenticator alongside the PIN.
	stepUp(t, c, map[string]string{"accountPasswordKey": pin}, http.StatusNoContent)
	var setup struct {
		Secret string `json:"secret"`
	}
	env.doJSON("POST", "/v1/accounts/me/totp/setup", c.authUser(), c.password, nil, http.StatusOK, &setup)
	secret, err := totpBase32.DecodeString(setup.Secret)
	if err != nil {
		t.Fatal(err)
	}
	code := func(offset int64) string { return totpCode(secret, time.Now().Unix()/totpPeriod+offset) }
	env.doJSON("POST", "/v1/accounts/me/totp/confirm", c.authUser(), c.password, map[string]string{"code": code(-1)}, http.StatusNoContent, nil)

	var methods struct {
		TwoStep        string   `json:"twoStep"`
		TwoStepMethods []string `json:"twoStepMethods"`
	}
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", c.authUser(), c.password, nil, http.StatusOK, &methods)
	if methods.TwoStep != "totp" || strings.Join(methods.TwoStepMethods, ",") != "totp,pin" {
		t.Fatalf("methods %+v", methods)
	}

	signIn := func(devicePassword string) twoStepReply {
		t.Helper()
		var locked struct {
			TwoStep struct {
				Ticket  string   `json:"ticket"`
				Method  string   `json:"method"`
				Methods []string `json:"methods"`
			} `json:"twoStep"`
		}
		if s := env.postJSON("/v1/accounts/oauth", map[string]string{"accessToken": token, "password": devicePassword}, &locked); s != http.StatusLocked ||
			locked.TwoStep.Method != "totp" || strings.Join(locked.TwoStep.Methods, ",") != "totp,pin" {
			t.Fatalf("locked %d %+v", s, locked)
		}
		var r twoStepReply
		r.TwoStep.Ticket = locked.TwoStep.Ticket
		return r
	}
	// Either answer passes.
	l := signIn("device-pw-456")
	var out twoStepReply
	if s := env.postJSON("/v1/accounts/two-step", map[string]string{"ticket": l.TwoStep.Ticket, "password": "device-pw-456", "accountPasswordKey": pin}, &out); s != http.StatusOK {
		t.Fatalf("pin answer %d %q", s, out.Error)
	}
	l = signIn("device-pw-789")
	if s := env.postJSON("/v1/accounts/two-step", map[string]string{"ticket": l.TwoStep.Ticket, "password": "device-pw-789", "code": code(0)}, &out); s != http.StatusOK {
		t.Fatalf("code answer %d %q", s, out.Error)
	}
	c = &client{env: env, accountID: out.AccountID, deviceID: out.DeviceID, password: "device-pw-789"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()

	// The PIN can't be removed while it's on; turned off on its own, the
	// authenticator stays.
	stepUp(t, c, map[string]string{"code": code(1)}, http.StatusNoContent)
	env.doJSON("DELETE", "/v1/accounts/me/account-password", c.authUser(), c.password, nil, http.StatusConflict, nil)
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]any{"method": "pin", "enabled": false}, http.StatusNoContent, nil)
	env.doJSON("DELETE", "/v1/accounts/me/account-password", c.authUser(), c.password, nil, http.StatusNoContent, nil)
	env.doJSON("GET", "/v1/accounts/me/sign-in-methods", c.authUser(), c.password, nil, http.StatusOK, &methods)
	if strings.Join(methods.TwoStepMethods, ",") != "totp" {
		t.Fatalf("after pin off %+v", methods)
	}
	// A password alone can't recover an account with an authenticator on.
	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPasswordKey": pin}, http.StatusNoContent, nil)
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]any{"method": "pin", "enabled": true}, http.StatusNoContent, nil)
	if ts, err := env.api.store.TwoStepFor(c.accountID); err != nil || ts.Joined() != "totp,pin" {
		t.Fatalf("pin back on %+v %v", ts, err)
	}
	// Turning the authenticator off clears it and keeps the PIN.
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]any{"method": "totp", "enabled": false}, http.StatusNoContent, nil)
	if ts, err := env.api.store.TwoStepFor(c.accountID); err != nil || ts.Joined() != "pin" || len(ts.TOTPSecret) != 0 {
		t.Fatalf("totp off %+v %v", ts, err)
	}
}

// Step-up asks before removing protection, not before adding it, and a
// device that just signed in through two-step doesn't have to answer again.
func TestStepUpOnlyToRemove(t *testing.T) {
	env := twoStepEnv(t)
	sfx := uniqueUsername("")
	token := "su" + sfx + "|su" + sfx + "@x.com"
	var first twoStepReply
	env.doJSON("POST", "/v1/accounts/oauth", "", "", map[string]string{
		"accessToken": token, "username": "su" + sfx, "password": "device-pw-123",
	}, http.StatusCreated, &first)
	c := &client{env: env, accountID: first.AccountID, deviceID: first.DeviceID, password: "device-pw-123"}
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()
	const pin = "pin-key-0123456789abcdefghijklmnopqrstuv"
	env.doJSON("PUT", "/v1/accounts/me/account-password", c.authUser(), c.password,
		map[string]string{"accountPasswordKey": pin}, http.StatusNoContent, nil)

	// Adding an authenticator alongside the PIN doesn't ask.
	var setup struct {
		Secret string `json:"secret"`
	}
	env.doJSON("POST", "/v1/accounts/me/totp/setup", c.authUser(), c.password, nil, http.StatusOK, &setup)
	secret, _ := totpBase32.DecodeString(setup.Secret)
	code := func(offset int64) string { return totpCode(secret, time.Now().Unix()/totpPeriod+offset) }
	env.doJSON("POST", "/v1/accounts/me/totp/confirm", c.authUser(), c.password, map[string]string{"code": code(-1)}, http.StatusNoContent, nil)
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]any{"method": "pin", "enabled": true}, http.StatusNoContent, nil)

	// Removing one, replacing the authenticator, or recovery-only does.
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]any{"method": "pin", "enabled": false}, http.StatusForbidden, nil)
	env.doJSON("PUT", "/v1/accounts/me/two-step", c.authUser(), c.password, map[string]any{"method": "recovery", "enabled": true}, http.StatusForbidden, nil)
	env.doJSON("POST", "/v1/accounts/me/totp/setup", c.authUser(), c.password, nil, http.StatusForbidden, nil)

	// A new device that signed in through two-step can make changes straight away.
	var locked struct {
		TwoStep struct {
			Ticket string `json:"ticket"`
		} `json:"twoStep"`
	}
	if s := env.postJSON("/v1/accounts/oauth", map[string]string{"accessToken": token, "password": "device-pw-456"}, &locked); s != http.StatusLocked {
		t.Fatalf("sign-in %d", s)
	}
	var out twoStepReply
	if s := env.postJSON("/v1/accounts/two-step", map[string]string{"ticket": locked.TwoStep.Ticket, "password": "device-pw-456", "code": code(0)}, &out); s != http.StatusOK {
		t.Fatalf("two-step %d %q", s, out.Error)
	}
	d := &client{env: env, accountID: out.AccountID, deviceID: out.DeviceID, password: "device-pw-456"}
	env.clients[d.authUser()] = d
	d.uploadDeviceAuthKey()
	env.doJSON("PUT", "/v1/accounts/me/two-step", d.authUser(), d.password, map[string]any{"method": "pin", "enabled": false}, http.StatusNoContent, nil)
}
