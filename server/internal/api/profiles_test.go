package api

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"io"
	"net/http"
	"testing"

	"github.com/relayapp/relay-server/internal/sendtoken"
	"github.com/relayapp/relay-server/internal/store"
)

func TestProfiles(t *testing.T) {
	env := newTestEnv(t)
	is := sendtoken.NewIssuer(bytes.Repeat([]byte{5}, 32))
	env.api.SetSendTokens(is, false)
	alice := env.register("alice-profile", "password-alice")
	tokens := getSendTokens(t, env, is, alice, 4)

	id := make([]byte, 32)
	rand.Read(id)
	path := "/v1/profiles/" + base64.RawURLEncoding.EncodeToString(id)
	secret := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	other := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32))

	do := func(method, write, token, etag string, body []byte) (int, string, []byte) {
		t.Helper()
		req, _ := http.NewRequest(method, env.srv.URL+path, bytes.NewReader(body))
		if write != "" {
			req.Header.Set(profileWriteHeader, write)
		}
		if token != "" {
			req.Header.Set(sendTokenHeader, token)
		}
		if etag != "" {
			req.Header.Set("If-None-Match", etag)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("ETag"), b
	}
	blob := bytes.Repeat([]byte{1}, store.ProfileBlobSize)

	if s, _, _ := do("GET", "", "", "", nil); s != http.StatusNotFound {
		t.Fatalf("missing profile: %d", s)
	}
	if s, _, _ := do("PUT", secret, "", "", blob); s != http.StatusUnauthorized {
		t.Fatalf("write without a token: %d", s)
	}
	if s, _, _ := do("PUT", secret, tokens[0], "", blob[:100]); s != http.StatusRequestEntityTooLarge {
		t.Fatalf("short blob: %d", s)
	}
	s, etag, _ := do("PUT", secret, tokens[1], "", blob)
	if s != http.StatusNoContent || etag == "" {
		t.Fatalf("write: %d %q", s, etag)
	}
	if s, _, _ := do("PUT", other, tokens[2], "", blob); s != http.StatusForbidden {
		t.Fatalf("someone else's write: %d", s)
	}
	s, got, body := do("GET", "", "", "", nil)
	if s != http.StatusOK || got != etag || !bytes.Equal(body, blob) {
		t.Fatalf("read: %d %q %d bytes", s, got, len(body))
	}
	if s, _, _ := do("GET", "", "", etag, nil); s != http.StatusNotModified {
		t.Fatalf("unchanged read: %d", s)
	}
	if s, _, _ := do("DELETE", other, "", "", nil); s != http.StatusForbidden {
		t.Fatalf("someone else's delete: %d", s)
	}
	if s, _, _ := do("DELETE", secret, "", "", nil); s != http.StatusNoContent {
		t.Fatalf("delete: %d", s)
	}
	if s, _, _ := do("GET", "", "", "", nil); s != http.StatusNotFound {
		t.Fatalf("after delete: %d", s)
	}
	// The id is free again, to anyone.
	if s, _, _ := do("PUT", other, tokens[3], "", blob); s != http.StatusNoContent {
		t.Fatalf("rewrite after delete: %d", s)
	}
}
