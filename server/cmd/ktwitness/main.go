// ktwitness is the key transparency witness. It runs on a different machine
// from the relay (the TURN box), follows the relay's signed heads, checks each
// one extends every head it saw before, co-signs it, and publishes the
// co-signed head to a public Gist (file kt-head.json). Apps require the
// co-signature, so faking a directory means compromising both machines. If a
// head doesn't extend what it saw, it stops co-signing and logs loudly.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/relayapp/relay-server/internal/kt"
)

type wireHead struct {
	Epoch   uint64 `json:"epoch"`
	SMTRoot []byte `json:"smtRoot"`
	LogSize uint64 `json:"logSize"`
	LogRoot []byte `json:"logRoot"`
	Time    uint64 `json:"time"`
	Sig     []byte `json:"sig"`
}

func (w wireHead) head() kt.Head {
	h := kt.Head{Epoch: w.Epoch, LogSize: w.LogSize, Time: w.Time, Sig: w.Sig}
	copy(h.SMTRoot[:], w.SMTRoot)
	copy(h.LogRoot[:], w.LogRoot)
	return h
}

func wire(h kt.Head) wireHead {
	return wireHead{Epoch: h.Epoch, SMTRoot: h.SMTRoot[:], LogSize: h.LogSize, LogRoot: h.LogRoot[:], Time: h.Time, Sig: h.Sig}
}

func main() {
	relay := flag.String("relay", "https://api.relaymsg.app", "relay base URL")
	relayKey := flag.String("relay-key", "", "the relay's built-in head signing key (base64)")
	keyFile := flag.String("key-file", "/var/lib/ktwitness/witness.key", "witness Ed25519 seed (hex); created on first run; apps build in its public half")
	stateFile := flag.String("state", "/var/lib/ktwitness/head.json", "the last head co-signed")
	gistID := flag.String("gist", "", "Gist to publish the co-signed head to")
	gistTokenFile := flag.String("gist-token-file", "", "GitHub token that can edit -gist")
	every := flag.Duration("every", 5*time.Minute, "how often to check for a new head")
	publicKey := flag.Bool("public-key", false, "print the witness public key and exit")
	flag.Parse()

	key, err := loadOrCreateKey(*keyFile)
	if err != nil {
		fail("witness key", err)
	}
	if *publicKey {
		fmt.Println(base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)))
		return
	}
	root, err := base64.StdEncoding.DecodeString(*relayKey)
	if err != nil || len(root) != ed25519.PublicKeySize {
		fail("relay key", errors.New("-relay-key must be a base64 Ed25519 public key"))
	}
	token, err := os.ReadFile(*gistTokenFile)
	if err != nil {
		fail("gist token", err)
	}
	w := &witness{relay: strings.TrimRight(*relay, "/"), root: root, key: key, state: *stateFile,
		gist: *gistID, token: strings.TrimSpace(string(token)), http: &http.Client{Timeout: 20 * time.Second}}
	for {
		if err := w.step(); err != nil {
			slog.Error("witness", "err", err)
		}
		time.Sleep(*every)
	}
}

func fail(what string, err error) {
	slog.Error(what, "err", err)
	os.Exit(1)
}

type witness struct {
	relay, state, gist, token string
	root                      ed25519.PublicKey
	key                       ed25519.PrivateKey
	http                      *http.Client
	halted                    bool
}

var errFork = errors.New("THE RELAY SHOWED A HEAD THAT DOESN'T EXTEND THE LAST ONE: not co-signing anything until this is investigated")

func (w *witness) step() error {
	if w.halted {
		return errFork
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	var endorsements struct {
		Endorsements []kt.Endorsement `json:"endorsements"`
	}
	if err := w.get(ctx, "/v1/kt/keys", &endorsements); err != nil {
		return fmt.Errorf("keys: %w", err)
	}
	trusted := kt.TrustedKeys("head", []ed25519.PublicKey{w.root}, endorsements.Endorsements)

	var got wireHead
	if err := w.get(ctx, "/v1/kt/head", &got); err != nil {
		return fmt.Errorf("head: %w", err)
	}
	head := got.head()
	if !head.VerifyAny(trusted) {
		return errors.New("head signature doesn't verify")
	}

	last, haveLast := w.lastHead()
	if haveLast {
		switch {
		case head.LogSize < last.LogSize:
			return nil // behind what we've seen; nothing new to sign
		case head.LogSize == last.LogSize:
			if head.LogRoot != last.LogRoot {
				w.halted = true
				return errFork
			}
			return nil
		}
		var proof struct {
			Proof [][]byte `json:"proof"`
		}
		q := url.Values{"from": {fmt.Sprint(last.LogSize)}, "to": {fmt.Sprint(head.LogSize)}}
		if err := w.get(ctx, "/v1/kt/consistency?"+q.Encode(), &proof); err != nil {
			return fmt.Errorf("consistency: %w", err)
		}
		hashes := make([][32]byte, len(proof.Proof))
		for i, p := range proof.Proof {
			copy(hashes[i][:], p)
		}
		if kt.VerifyConsistency(int(last.LogSize), int(head.LogSize), last.LogRoot, head.LogRoot, hashes) != nil {
			w.halted = true
			return errFork
		}
	}

	cosig := ed25519.Sign(w.key, head.WitnessBytes())
	out, _ := json.MarshalIndent(map[string]any{
		"epoch": head.Epoch, "smtRoot": head.SMTRoot[:], "logSize": head.LogSize,
		"logRoot": head.LogRoot[:], "time": head.Time, "sig": head.Sig,
		"witnessSig":   cosig,
		"endorsements": endorsements.Endorsements,
	}, "", "  ")
	if err := w.publish(ctx, out); err != nil {
		return fmt.Errorf("publish: %w", err)
	}
	if err := w.saveHead(head); err != nil {
		return err
	}
	slog.Info("co-signed", "epoch", head.Epoch, "logSize", head.LogSize)
	return nil
}

func (w *witness) get(ctx context.Context, path string, into any) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", w.relay+path, nil)
	resp, err := w.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(into)
}

func (w *witness) publish(ctx context.Context, content []byte) error {
	body, _ := json.Marshal(map[string]any{
		"files": map[string]any{"kt-head.json": map[string]string{"content": string(content) + "\n"}},
	})
	req, _ := http.NewRequestWithContext(ctx, "PATCH", "https://api.github.com/gists/"+w.gist, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+w.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := w.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("github: status %d", resp.StatusCode)
	}
	return nil
}

func (w *witness) lastHead() (kt.Head, bool) {
	data, err := os.ReadFile(w.state)
	if err != nil {
		return kt.Head{}, false
	}
	var h wireHead
	if json.Unmarshal(data, &h) != nil {
		return kt.Head{}, false
	}
	return h.head(), true
}

func (w *witness) saveHead(h kt.Head) error {
	data, _ := json.Marshal(wire(h))
	tmp := w.state + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, w.state)
}

func loadOrCreateKey(path string) (ed25519.PrivateKey, error) {
	if data, err := os.ReadFile(path); err == nil {
		seed, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, errors.New("key file must be a hex Ed25519 seed")
		}
		return ed25519.NewKeyFromSeed(seed), nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, []byte(hex.EncodeToString(seed)+"\n"), 0o600); err != nil {
		return nil, err
	}
	return ed25519.NewKeyFromSeed(seed), nil
}
