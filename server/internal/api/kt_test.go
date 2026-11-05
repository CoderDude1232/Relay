package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/kt"
)

// TestKTLookupSealed: the anonymous key-transparency lookup needs the target's
// access key, answers unknown accounts and wrong keys identically, and serves
// the same proof as the signed lookup.
func TestKTLookupSealed(t *testing.T) {
	env := newTestEnv(t)
	vrfKey, signKey, err := kt.LoadOrCreateKeys(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	dir := kt.NewDirectory(vrfKey, signKey)
	env.api.kt = dir

	bob := env.register("bob-ktsealed", "password-bob")
	bob.uploadKeys(1)
	accessKey := bytes.Repeat([]byte{0x55}, 32)
	env.doJSON("PUT", "/v1/accounts/me/access-key", bob.authUser(), bob.password,
		map[string]string{"accessKey": base64.StdEncoding.EncodeToString(accessKey)},
		http.StatusNoContent, nil)
	current, err := env.api.store.KTCurrentKeys()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := dir.Sync(current); err != nil {
		t.Fatal(err)
	}
	if _, _, err := dir.Publish(time.Now(), nil); err != nil {
		t.Fatal(err)
	}

	lookup := func(account string, key []byte, header bool) (int, map[string]json.RawMessage) {
		t.Helper()
		req, _ := http.NewRequest("GET", env.srv.URL+"/v1/kt/lookup/"+account+"/sealed", nil)
		if header {
			req.Header.Set("Relay-Access-Key", base64.StdEncoding.EncodeToString(key))
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var body map[string]json.RawMessage
		json.NewDecoder(resp.Body).Decode(&body)
		return resp.StatusCode, body
	}

	if code, _ := lookup(bob.accountID, nil, false); code != http.StatusForbidden {
		t.Fatalf("no access key: got %d, want 403", code)
	}
	if code, _ := lookup(bob.accountID, bytes.Repeat([]byte{0x66}, 32), true); code != http.StatusForbidden {
		t.Fatalf("wrong access key: got %d, want 403", code)
	}
	if code, _ := lookup("00000000-0000-0000-0000-000000000000", accessKey, true); code != http.StatusForbidden {
		t.Fatalf("unknown account: got %d, want 403 (same as a wrong key)", code)
	}
	code, body := lookup(bob.accountID, accessKey, true)
	if code != http.StatusOK || len(body["vrfProof"]) == 0 || len(body["proof"]) == 0 || len(body["keys"]) == 0 {
		t.Fatalf("right access key: got %d %v", code, body)
	}
}
