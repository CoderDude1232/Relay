package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
)

// TestSealedKeyFetch: the anonymous key fetch needs the target's access key,
// answers unknown accounts and wrong keys identically, and doesn't echo the
// access key back.
func TestSealedKeyFetch(t *testing.T) {
	env := newTestEnv(t)
	bob := env.register("bob-sealedkeys", "password-bob")
	bob.uploadKeys(2)
	accessKey := bytes.Repeat([]byte{0x33}, 32)
	env.doJSON("PUT", "/v1/accounts/me/access-key", bob.authUser(), bob.password,
		map[string]string{"accessKey": base64.StdEncoding.EncodeToString(accessKey)},
		http.StatusNoContent, nil)

	fetch := func(account string, key []byte, header bool) (int, map[string]json.RawMessage) {
		t.Helper()
		req, _ := http.NewRequest("GET", env.srv.URL+"/v1/keys/"+account+"/sealed", nil)
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

	if code, _ := fetch(bob.accountID, nil, false); code != http.StatusForbidden {
		t.Fatalf("no access key: got %d, want 403", code)
	}
	if code, _ := fetch(bob.accountID, bytes.Repeat([]byte{0x44}, 32), true); code != http.StatusForbidden {
		t.Fatalf("wrong access key: got %d, want 403", code)
	}
	if code, _ := fetch("00000000-0000-0000-0000-000000000000", accessKey, true); code != http.StatusForbidden {
		t.Fatalf("unknown account: got %d, want 403 (same as a wrong key)", code)
	}
	code, body := fetch(bob.accountID, accessKey, true)
	if code != http.StatusOK {
		t.Fatalf("right access key: got %d, want 200", code)
	}
	var devices []map[string]json.RawMessage
	json.Unmarshal(body["devices"], &devices)
	if len(devices) == 0 || len(devices[0]["mailboxId"]) == 0 || len(devices[0]["identityKey"]) == 0 {
		t.Fatalf("bundle missing fields: %v", body)
	}
	if _, ok := body["accessKey"]; ok {
		t.Fatal("anonymous fetch must not echo the access key")
	}
}
