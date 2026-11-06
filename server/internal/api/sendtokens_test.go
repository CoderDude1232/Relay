package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"testing"

	"github.com/gtank/ristretto255"

	"github.com/relayapp/relay-server/internal/sendtoken"
)

// getSendTokens has c fetch n tokens for today, as the app does.
func getSendTokens(t *testing.T, env *testEnv, is *sendtoken.Issuer, c *client, n int) []string {
	t.Helper()
	day := is.Today()
	var rs []*ristretto255.Scalar
	var nonces, blinded [][]byte
	var req struct {
		Day     int64    `json:"day"`
		Blinded []string `json:"blinded"`
	}
	req.Day = day
	for i := 0; i < n; i++ {
		var rb [64]byte
		rb[0], rb[1] = byte(i+1), 0x55
		r := ristretto255.NewScalar().FromUniformBytes(rb[:])
		nonce := bytes.Repeat([]byte{byte(i + 1)}, sendtoken.NonceLength)
		nonce[0] = byte(len(env.t.Name()))
		b := sendtoken.Blind(day, nonce, r)
		rs, nonces, blinded = append(rs, r), append(nonces, nonce), append(blinded, b)
		req.Blinded = append(req.Blinded, base64.StdEncoding.EncodeToString(b))
	}
	body, _ := json.Marshal(req)
	hr, _ := http.NewRequest("POST", env.srv.URL+"/v1/send-tokens", bytes.NewReader(body))
	hr.Header.Set("Content-Type", "application/json")
	c.sign(hr, body)
	resp, err := http.DefaultClient.Do(hr)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("send-tokens: %d %s", resp.StatusCode, raw)
	}
	var out struct {
		Day    int64 `json:"day"`
		Tokens []struct {
			Evaluated, Proof string
		} `json:"tokens"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Tokens) != n {
		t.Fatalf("send-tokens body: %s", raw)
	}
	var tokens []string
	for i, tok := range out.Tokens {
		e, _ := base64.StdEncoding.DecodeString(tok.Evaluated)
		p, _ := base64.StdEncoding.DecodeString(tok.Proof)
		point, ok := sendtoken.Finish(is.PublicKey(), blinded[i], e, p, rs[i])
		if !ok {
			t.Fatal("proof didn't verify")
		}
		tokens = append(tokens, sendtoken.Format(day, nonces[i], point))
	}
	return tokens
}

func TestSendTokens(t *testing.T) {
	env := newTestEnv(t)
	is := sendtoken.NewIssuer(bytes.Repeat([]byte{4}, 32))
	env.api.SetSendTokens(is, false)
	alice := env.register("alice-tokens", "password-alice")
	bob := env.register("bob-tokens", "password-bob")
	bob.uploadKeys(2)
	accessKey := bytes.Repeat([]byte{0x11}, 32)
	env.doJSON("PUT", "/v1/accounts/me/access-key", bob.authUser(), bob.password,
		map[string]string{"accessKey": base64.StdEncoding.EncodeToString(accessKey)}, http.StatusNoContent, nil)
	var keys struct {
		Devices []struct {
			MailboxID string `json:"mailboxId"`
		} `json:"devices"`
	}
	env.doJSON("GET", "/v1/keys/"+bob.accountID, alice.authUser(), alice.password, nil, http.StatusOK, &keys)
	mailbox := keys.Devices[0].MailboxID

	send := func(token string) int {
		body, _ := json.Marshal(map[string]any{
			"mailboxId": mailbox, "type": 2,
			"content":   base64.StdEncoding.EncodeToString([]byte("sealed")),
			"accessKey": base64.StdEncoding.EncodeToString(accessKey),
		})
		req, _ := http.NewRequest("POST", env.srv.URL+"/v1/messages/sealed", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set(sendTokenHeader, token)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	tokens := getSendTokens(t, env, is, alice, 3)
	if s := send(tokens[0]); s != http.StatusOK {
		t.Fatalf("send with token: %d", s)
	}
	if s := send(tokens[0]); s != http.StatusUnauthorized {
		t.Fatalf("reused token: %d", s)
	}
	if s := send("1.garbage"); s != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", s)
	}
	// An old app without a token still gets through, by IP.
	if s := send(""); s != http.StatusOK {
		t.Fatalf("no token, not required: %d", s)
	}
	// Once required, it's told to update.
	env.api.SetSendTokens(is, true)
	if s := send(""); s != http.StatusUpgradeRequired {
		t.Fatalf("no token, required: %d", s)
	}
	if s := send(tokens[1]); s != http.StatusOK {
		t.Fatalf("token, required: %d", s)
	}
	// Sealed key fetches take them too.
	req, _ := http.NewRequest("GET", env.srv.URL+"/v1/keys/"+bob.accountID+"/sealed", nil)
	req.Header.Set("Relay-Access-Key", base64.StdEncoding.EncodeToString(accessKey))
	req.Header.Set(sendTokenHeader, tokens[2])
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("sealed key fetch with token: %d", resp.StatusCode)
	}

	// Wrong day: the relay's day and no tokens.
	body, _ := json.Marshal(map[string]any{"day": is.Today() - 1, "blinded": []string{base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))}})
	hr, _ := http.NewRequest("POST", env.srv.URL+"/v1/send-tokens", bytes.NewReader(body))
	hr.Header.Set("Content-Type", "application/json")
	alice.sign(hr, body)
	resp, err = http.DefaultClient.Do(hr)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var wrong struct {
		Day    int64 `json:"day"`
		Tokens []any `json:"tokens"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrong); err != nil || resp.StatusCode != http.StatusOK ||
		wrong.Day != is.Today() || len(wrong.Tokens) != 0 {
		t.Fatalf("wrong day: %d %+v", resp.StatusCode, wrong)
	}
}
