package api

import (
	"crypto/rand"
	"crypto/subtle"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/store"
)

// Fallback addresses: Cloudflare Workers on workers.dev that pass requests
// through to this relay, for networks that block api.relaymsg.app by name.
// cmd/fallbackrotate creates new ones every few days and writes the current
// hostnames to a file; signed-in devices fetch the list here while they can
// still connect, so they have it once the main address is blocked.

// fallbackKey is the secret the Workers send with each request; with it, their
// X-Relay-Client-IP header names the real client (otherwise every user of a
// Worker would share its address for rate limits). Empty disables the header.
var fallbackKey string

// SetFallbackKey sets the shared secret the fallback Workers present.
func SetFallbackKey(key string) {
	fallbackKey = strings.TrimSpace(key)
}

// fallbackClientAddr is the client address a fallback Worker vouches for, if
// the request carries the Worker secret.
func fallbackClientAddr(r *http.Request) (string, bool) {
	if fallbackKey == "" {
		return "", false
	}
	given := r.Header.Get("X-Relay-Fallback-Key")
	if given == "" || subtle.ConstantTimeCompare([]byte(given), []byte(fallbackKey)) != 1 {
		return "", false
	}
	client, err := netip.ParseAddr(strings.TrimSpace(r.Header.Get("X-Relay-Client-IP")))
	if err != nil {
		return "", false
	}
	return client.Unmap().String(), true
}

// fallbackHosts reads the rotation's hostname file, one per line, newest
// first, and re-reads it when it changes.
type fallbackHosts struct {
	path string

	mu      sync.Mutex
	modTime time.Time
	hosts   []string
}

func (f *fallbackHosts) current() []string {
	if f == nil || f.path == "" {
		return nil
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	info, err := os.Stat(f.path)
	if err != nil {
		return f.hosts
	}
	if !info.ModTime().Equal(f.modTime) {
		if data, err := os.ReadFile(f.path); err == nil {
			f.hosts = parseFallbackHosts(string(data))
			f.modTime = info.ModTime()
		}
	}
	return f.hosts
}

func parseFallbackHosts(text string) []string {
	var hosts []string
	for _, line := range strings.Split(text, "\n") {
		host := strings.ToLower(strings.TrimSpace(line))
		if host == "" || strings.HasPrefix(host, "#") || len(host) > 253 {
			continue
		}
		ok := strings.Contains(host, ".")
		for _, c := range host {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
				ok = false
				break
			}
		}
		if ok {
			hosts = append(hosts, host)
		}
		if len(hosts) == 10 {
			break
		}
	}
	return hosts
}

// SetFallbackHostsFile names the file cmd/fallbackrotate keeps up to date.
func (s *Server) SetFallbackHostsFile(path string) {
	s.fallbacks = &fallbackHosts{path: path}
}

// GET /v1/fallbacks → 200 {hosts: [...]}: addresses that reach this relay if
// the main one is blocked. Signed-in devices only, so a network filter can't
// simply fetch the list and block it.
func (s *Server) handleFallbacks(w http.ResponseWriter, r *http.Request, _ *store.Device) {
	hosts := s.fallbacks.current()
	if hosts == nil {
		hosts = []string{}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"hosts": hosts})
}

// GET /v1/ping → 204 with X-Relay: 1. Lets a client tell this relay from a
// network's block page when it tries a fallback address.
func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Relay", "1")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

// speedTestLimiter: a proxy check downloads a few hundred KB; 20 a minute per
// address is plenty and keeps the endpoint from being a bandwidth sink.
var speedTestLimiter = newSlidingWindowLimiter(20, time.Minute)

const maxSpeedTestKB = 512

// GET /v1/speedtest?kb=N → N KB of random bytes (default 256, at most 512),
// uncompressible and uncached, so the app can measure a proxy's throughput.
func (s *Server) handleSpeedTest(w http.ResponseWriter, r *http.Request) {
	if !speedTestLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "slow down")
		return
	}
	kb := 256
	if v, err := strconv.Atoi(r.URL.Query().Get("kb")); err == nil && v > 0 {
		kb = min(v, maxSpeedTestKB)
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.Itoa(kb*1024))
	chunk := make([]byte, 1024)
	for i := 0; i < kb; i++ {
		_, _ = rand.Read(chunk)
		if _, err := w.Write(chunk); err != nil {
			return
		}
	}
}
