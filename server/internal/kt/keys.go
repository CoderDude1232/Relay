package kt

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
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

// LoadEndorsements reads endorsements.json from the key directory (none if
// it doesn't exist).
func LoadEndorsements(dir string) ([]Endorsement, error) {
	data, err := os.ReadFile(filepath.Join(dir, "endorsements.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	var out []Endorsement
	return out, json.Unmarshal(data, &out)
}

// RotateSignKey replaces sign.key with a new key endorsed by the old one,
// which is kept as sign.key.<time>.old. Apps already trust the old key and
// learn the new one from the endorsement, so no app update is needed.
// Returns the new public key.
func RotateSignKey(dir string) (ed25519.PublicKey, error) {
	_, old, err := LoadOrCreateKeys(dir)
	if err != nil {
		return nil, err
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, err
	}
	next := ed25519.NewKeyFromSeed(seed)
	endorsements, err := LoadEndorsements(dir)
	if err != nil {
		return nil, err
	}
	endorsements = append(endorsements, Endorse("head", old, next.Public().(ed25519.PublicKey)))
	data, _ := json.MarshalIndent(endorsements, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, "endorsements.json"), data, 0o644); err != nil {
		return nil, err
	}
	signPath := filepath.Join(dir, "sign.key")
	if err := os.Rename(signPath, fmt.Sprintf("%s.%d.old", signPath, time.Now().Unix())); err != nil {
		return nil, err
	}
	if err := os.WriteFile(signPath, []byte(hex.EncodeToString(seed)+"\n"), 0o600); err != nil {
		return nil, err
	}
	return next.Public().(ed25519.PublicKey), nil
}
