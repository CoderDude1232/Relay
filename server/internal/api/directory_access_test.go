package api

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"testing"

	"github.com/relayapp/relay-server/internal/oprf"
)

// TestDirectoryCarriesAccessKey: after an account publishes its access key, a
// client that finds it by username gets the key (sealed under the entry's
// token) and can fetch its keys anonymously from the first contact.
func TestDirectoryCarriesAccessKey(t *testing.T) {
	env := newTestEnv(t)
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	alice := env.register("alice-dirak", "password-alice")
	bob := env.register("bob-dirak", "password-bob")
	bob.uploadKeys(1)
	accessKey := bytes.Repeat([]byte{0x5a}, 32)
	env.doJSON("PUT", "/v1/accounts/me/access-key", bob.authUser(), bob.password,
		map[string]string{"accessKey": base64.StdEncoding.EncodeToString(accessKey)}, http.StatusNoContent, nil)

	tok := key.Token(bob.username)
	var resp struct {
		Buckets []struct {
			Entries []struct {
				Tag       string `json:"tag"`
				AccessBox string `json:"accessBox"`
			} `json:"entries"`
		} `json:"buckets"`
	}
	env.doJSON("POST", "/v1/directory/buckets", alice.authUser(), alice.password,
		map[string]any{"buckets": []int{int(oprf.DirectoryBucket(tok))}}, http.StatusOK, &resp)
	want := base64.StdEncoding.EncodeToString(oprf.DirectoryTag(tok))
	var box []byte
	for _, b := range resp.Buckets {
		for _, e := range b.Entries {
			if e.Tag == want {
				box, _ = base64.StdEncoding.DecodeString(e.AccessBox)
			}
		}
	}
	if len(box) == 0 {
		t.Fatal("directory entry has no accessBox after the access key was set")
	}
	// Open it the way the iOS client does (HKDF-SHA256(token, "relay-entry"),
	// AES-GCM with AD "relay-access-key").
	k, err := hkdf.Key(sha256.New, tok, nil, "relay-entry", 32)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(k)
	aead, _ := cipher.NewGCM(block)
	got, err := aead.Open(nil, box[:aead.NonceSize()], box[aead.NonceSize():], []byte("relay-access-key"))
	if err != nil || !bytes.Equal(got, accessKey) {
		t.Fatalf("access box didn't open to the access key: %v", err)
	}
}
