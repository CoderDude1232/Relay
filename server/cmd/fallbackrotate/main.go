// fallbackrotate keeps a few fallback addresses for the relay on Cloudflare
// Workers (workers.dev), for networks that block api.relaymsg.app by name.
// Every -every it deploys worker.js under a new random name, checks it reaches
// the relay, retires ones older than -keep (always keeping at least two), and
// writes the live hostnames, newest first, to -hosts for relayd to serve at
// GET /v1/fallbacks. Run it from a systemd timer; each run does at most one
// rotation.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

//go:embed worker.js
var workerSource []byte

const apiBase = "https://api.cloudflare.com/client/v4"

func main() {
	accountID := flag.String("account", "", "Cloudflare account id")
	tokenFile := flag.String("token-file", "", "file holding a Cloudflare API token with Workers Scripts:Edit")
	keyFile := flag.String("key-file", "", "file holding the secret shared with relayd (-fallback-key-file)")
	hostsFile := flag.String("hosts", "/var/lib/relay/fallback-hosts", "hostname file relayd reads")
	stateFile := flag.String("state", "/var/lib/relay/fallback-workers.json", "the Workers this tool manages")
	every := flag.Duration("every", 72*time.Hour, "deploy a new Worker when the newest is this old")
	keep := flag.Duration("keep", 7*24*time.Hour, "retire Workers older than this")
	anchor := flag.String("anchor", "", "a Worker name that's never rotated; built into the app for devices without a list yet")
	signKeyFile := flag.String("sign-key", "", "Ed25519 seed (hex) that signs the published list; -gen-key makes one")
	genKey := flag.Bool("gen-key", false, "write a new signing seed to -sign-key, print its public key and exit")
	publicKey := flag.Bool("public-key", false, "print the public key for -sign-key (built into the app) and exit")
	gistID := flag.String("gist", "", "GitHub Gist that carries the signed list (file fallbacks.json)")
	gistTokenFile := flag.String("gist-token-file", "", "file holding a GitHub token that can edit -gist")
	signedOut := flag.String("signed-out", "", "also write the signed list to this file")
	flag.Parse()

	if *genKey || *publicKey {
		if *genKey {
			seed := make([]byte, ed25519.SeedSize)
			_, _ = rand.Read(seed)
			if err := writeAtomic(*signKeyFile, []byte(hex.EncodeToString(seed)+"\n"), 0o600); err != nil {
				fail("write sign key", err)
			}
		}
		priv, err := loadSignKey(*signKeyFile)
		if err != nil {
			fail("read sign key", err)
		}
		fmt.Println(base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey)))
		return
	}

	token, err := os.ReadFile(*tokenFile)
	if err != nil {
		fail("read token", err)
	}
	key, err := os.ReadFile(*keyFile)
	if err != nil {
		fail("read key", err)
	}
	cf := &cloudflare{account: *accountID, token: strings.TrimSpace(string(token)), http: &http.Client{Timeout: 30 * time.Second}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	subdomain, err := cf.subdomain(ctx)
	if err != nil {
		fail("read workers.dev subdomain", err)
	}
	state := loadState(*stateFile)
	now := time.Now()
	// Addresses follow the account's workers.dev subdomain, which can be renamed.
	for i := range state.Workers {
		state.Workers[i].Host = state.Workers[i].Name + "." + subdomain + ".workers.dev"
	}

	if len(state.Workers) == 0 || now.Sub(state.Workers[0].Created) >= *every {
		name := randomName()
		if err := cf.deploy(ctx, name, strings.TrimSpace(string(key))); err != nil {
			fail("deploy", err)
		}
		host := name + "." + subdomain + ".workers.dev"
		if err := waitReachable(ctx, host); err != nil {
			// Leave it out of the list; the next run retries with a new name.
			slog.Error("new worker isn't reaching the relay; removing it", "host", host, "err", err)
			_ = cf.remove(ctx, name)
		} else {
			slog.Info("deployed fallback", "host", host)
			state.Workers = append([]managedWorker{{Name: name, Host: host, Created: now}}, state.Workers...)
		}
	}

	// Retire old ones, newest two always stay.
	sort.Slice(state.Workers, func(i, j int) bool { return state.Workers[i].Created.After(state.Workers[j].Created) })
	var kept []managedWorker
	for i, w := range state.Workers {
		if i >= 2 && now.Sub(w.Created) > *keep {
			if err := cf.remove(ctx, w.Name); err != nil {
				slog.Error("retire worker", "name", w.Name, "err", err)
				kept = append(kept, w)
				continue
			}
			slog.Info("retired fallback", "host", w.Host)
			continue
		}
		kept = append(kept, w)
	}
	state.Workers = kept
	if err := saveState(*stateFile, state); err != nil {
		fail("save state", err)
	}

	// The anchor stays put; redeployed only if it's missing or not answering.
	if *anchor != "" {
		host := *anchor + "." + subdomain + ".workers.dev"
		if err := waitReachableOnce(ctx, host); err != nil {
			if err := cf.deploy(ctx, *anchor, strings.TrimSpace(string(key))); err != nil {
				slog.Error("deploy anchor", "err", err)
			} else if err := waitReachable(ctx, host); err != nil {
				slog.Error("anchor isn't reaching the relay", "host", host, "err", err)
			} else {
				slog.Info("deployed anchor", "host", host)
			}
		}
	}

	var hosts strings.Builder
	hosts.WriteString("# written by fallbackrotate; newest first\n")
	for _, w := range state.Workers {
		hosts.WriteString(w.Host + "\n")
	}
	if *anchor != "" {
		hosts.WriteString(*anchor + "." + subdomain + ".workers.dev\n")
	}
	if err := writeAtomic(*hostsFile, []byte(hosts.String()), 0o644); err != nil {
		fail("write hosts", err)
	}

	// The same list, signed, where a blocked device can still find it.
	if *signKeyFile != "" {
		priv, err := loadSignKey(*signKeyFile)
		if err != nil {
			fail("read sign key", err)
		}
		var live []string
		for _, w := range state.Workers {
			live = append(live, w.Host)
		}
		if *anchor != "" {
			live = append(live, *anchor+"."+subdomain+".workers.dev")
		}
		signed := signList(priv, live, now)
		if *signedOut != "" {
			if err := writeAtomic(*signedOut, signed, 0o644); err != nil {
				slog.Error("write signed list", "err", err)
			}
		}
		if *gistID != "" {
			// Publishing is a bonus: without a token the rotation still counts.
			if token, err := os.ReadFile(*gistTokenFile); err != nil {
				slog.Error("read gist token; list not published", "err", err)
			} else if err := updateGist(ctx, *gistID, strings.TrimSpace(string(token)), signed); err != nil {
				slog.Error("publish list", "err", err)
			} else {
				slog.Info("published list", "hosts", len(live))
			}
		}
	}
}

func loadSignKey(path string) (ed25519.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	seed, err := hex.DecodeString(strings.TrimSpace(string(data)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, errors.New("sign key must be a hex Ed25519 seed")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// signList: {"v":1,"issued":<unix>,"hosts":[...],"sig":<base64>}. The
// signature covers "relay-fallbacks-v1\n<issued>\n" and each host plus "\n";
// RelayFallback.swift checks it with the public key.
func signList(priv ed25519.PrivateKey, hosts []string, now time.Time) []byte {
	issued := now.Unix()
	msg := fmt.Sprintf("relay-fallbacks-v1\n%d\n", issued)
	for _, h := range hosts {
		msg += h + "\n"
	}
	out, _ := json.MarshalIndent(map[string]any{
		"v":      1,
		"issued": issued,
		"hosts":  hosts,
		"sig":    base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(msg))),
	}, "", "  ")
	return append(out, '\n')
}

func updateGist(ctx context.Context, id, token string, content []byte) error {
	body, _ := json.Marshal(map[string]any{
		"files": map[string]any{"fallbacks.json": map[string]string{"content": string(content)}},
	})
	req, err := http.NewRequestWithContext(ctx, "PATCH", "https://api.github.com/gists/"+id, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("github: status %d", resp.StatusCode)
	}
	return nil
}

func fail(what string, err error) {
	slog.Error(what, "err", err)
	os.Exit(1)
}

// randomName looks like nothing in particular: a letter, then 9 letters or digits.
func randomName() string {
	const letters = "abcdefghijklmnopqrstuvwxyz"
	const alnum = letters + "0123456789"
	b := make([]byte, 10)
	_, _ = rand.Read(b)
	out := []byte{letters[int(b[0])%len(letters)]}
	for _, c := range b[1:] {
		out = append(out, alnum[int(c)%len(alnum)])
	}
	return string(out)
}

// waitReachableOnce checks an address a single time.
func waitReachableOnce(ctx context.Context, host string) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://"+host+"/v1/ping", nil)
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("X-Relay") != "1" {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

// waitReachable polls the new address until the relay answers through it; a
// fresh workers.dev route can take a minute to appear.
func waitReachable(ctx context.Context, host string) error {
	client := &http.Client{Timeout: 10 * time.Second}
	var last error
	for i := 0; i < 18; i++ {
		req, _ := http.NewRequestWithContext(ctx, "GET", "https://"+host+"/v1/ping", nil)
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusNoContent && resp.Header.Get("X-Relay") == "1" {
				return nil
			}
			last = fmt.Errorf("status %d", resp.StatusCode)
		} else {
			last = err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Second):
		}
	}
	return last
}

// MARK: state

type managedWorker struct {
	Name    string    `json:"name"`
	Host    string    `json:"host"`
	Created time.Time `json:"created"`
}

type rotationState struct {
	Workers []managedWorker `json:"workers"` // newest first
}

func loadState(path string) rotationState {
	var s rotationState
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	return s
}

func saveState(path string, s rotationState) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, data, 0o600)
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// MARK: Cloudflare API

type cloudflare struct {
	account string
	token   string
	http    *http.Client
}

type cfResponse struct {
	Success bool                       `json:"success"`
	Errors  []struct{ Message string } `json:"errors"`
	Result  json.RawMessage            `json:"result"`
}

func (c *cloudflare) do(ctx context.Context, method, path, contentType string, body io.Reader) (json.RawMessage, error) {
	req, err := http.NewRequestWithContext(ctx, method, apiBase+"/accounts/"+c.account+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out cfResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return nil, fmt.Errorf("%s %s: status %d", method, path, resp.StatusCode)
	}
	if !out.Success {
		var msgs []string
		for _, e := range out.Errors {
			msgs = append(msgs, e.Message)
		}
		return nil, fmt.Errorf("%s %s: %s", method, path, strings.Join(msgs, "; "))
	}
	return out.Result, nil
}

// subdomain is the account's workers.dev name (<name>.<subdomain>.workers.dev).
func (c *cloudflare) subdomain(ctx context.Context) (string, error) {
	raw, err := c.do(ctx, "GET", "/workers/subdomain", "", nil)
	if err != nil {
		return "", err
	}
	var r struct{ Subdomain string }
	if err := json.Unmarshal(raw, &r); err != nil || r.Subdomain == "" {
		return "", errors.New("no workers.dev subdomain: open Workers & Pages in the Cloudflare dashboard once to create it")
	}
	return r.Subdomain, nil
}

func (c *cloudflare) deploy(ctx context.Context, name, key string) error {
	var buf bytes.Buffer
	form := multipart.NewWriter(&buf)
	metadata, _ := json.Marshal(map[string]any{
		"main_module":        "worker.js",
		"compatibility_date": "2025-01-01",
		"bindings":           []map[string]string{{"type": "secret_text", "name": "FALLBACK_KEY", "text": key}},
	})
	if err := form.WriteField("metadata", string(metadata)); err != nil {
		return err
	}
	part, err := form.CreatePart(textproto.MIMEHeader{
		"Content-Disposition": {`form-data; name="worker.js"; filename="worker.js"`},
		"Content-Type":        {"application/javascript+module"},
	})
	if err != nil {
		return err
	}
	if _, err := part.Write(workerSource); err != nil {
		return err
	}
	if err := form.Close(); err != nil {
		return err
	}
	if _, err := c.do(ctx, "PUT", "/workers/scripts/"+name, form.FormDataContentType(), &buf); err != nil {
		return err
	}
	_, err = c.do(ctx, "POST", "/workers/scripts/"+name+"/subdomain", "application/json",
		strings.NewReader(`{"enabled":true,"previews_enabled":false}`))
	return err
}

func (c *cloudflare) remove(ctx context.Context, name string) error {
	_, err := c.do(ctx, "DELETE", "/workers/scripts/"+name+"?force=true", "", nil)
	return err
}
