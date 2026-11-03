package kt

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// LoadOrCreateKeys reads the VRF key (vrf.pem) and head-signing key
// (sign.key, hex Ed25519 seed) from dir, creating them on first run. The app
// has the public halves built in: never replace them.
func LoadOrCreateKeys(dir string) (*rsa.PrivateKey, ed25519.PrivateKey, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, err
	}
	vrfPath, signPath := filepath.Join(dir, "vrf.pem"), filepath.Join(dir, "sign.key")

	var vrfKey *rsa.PrivateKey
	if data, err := os.ReadFile(vrfPath); err == nil {
		block, _ := pem.Decode(data)
		if block == nil {
			return nil, nil, errors.New("kt: vrf.pem isn't PEM")
		}
		if vrfKey, err = x509.ParsePKCS1PrivateKey(block.Bytes); err != nil {
			return nil, nil, fmt.Errorf("kt: vrf.pem: %w", err)
		}
	} else if errors.Is(err, os.ErrNotExist) {
		if vrfKey, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
			return nil, nil, err
		}
		out := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(vrfKey)})
		if err := os.WriteFile(vrfPath, out, 0o600); err != nil {
			return nil, nil, err
		}
	} else {
		return nil, nil, err
	}

	var signKey ed25519.PrivateKey
	if data, err := os.ReadFile(signPath); err == nil {
		seed, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, nil, errors.New("kt: sign.key must be a hex Ed25519 seed")
		}
		signKey = ed25519.NewKeyFromSeed(seed)
	} else if errors.Is(err, os.ErrNotExist) {
		seed := make([]byte, ed25519.SeedSize)
		if _, err := rand.Read(seed); err != nil {
			return nil, nil, err
		}
		if err := os.WriteFile(signPath, []byte(hex.EncodeToString(seed)+"\n"), 0o600); err != nil {
			return nil, nil, err
		}
		signKey = ed25519.NewKeyFromSeed(seed)
	} else {
		return nil, nil, err
	}
	return vrfKey, signKey, nil
}
