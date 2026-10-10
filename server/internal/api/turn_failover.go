package api

// TURN failover: our own coturn is the only TURN server handed to clients while
// it's healthy. A background prober checks it every few seconds with a STUN
// Binding Request (is it answering?) and the load agent on the TURN box
// (cmd/turnload: is it near its bandwidth/packet/CPU limits?). New calls move
// to Cloudflare's TURN service before the box is overwhelmed (the host has no
// DDoS filtering), and come back once it settles. Cloudflare is never
// contacted, and sees no call traffic, while coturn is healthy.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// iceServer is one entry of the iceServers list in GET /v1/turn-credentials,
// in WebRTC's RTCIceServer shape.
type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// TURNHealth tracks whether our coturn answers STUN and isn't overloaded.
type TURNHealth struct {
	addr      string // host:port probed over UDP
	statusURL string // turnload agent; empty = liveness only
	client    *http.Client
	unhealthy atomic.Bool

	// On-demand checks (a phone reporting its call's relay failed) are
	// coalesced: one probe at a time, its result reused for a few seconds.
	checkMu     sync.Mutex
	lastCheckAt time.Time
	lastCheckOK bool
}

const (
	turnProbeInterval = 5 * time.Second
	turnProbeTimeout  = 3 * time.Second
	// Consecutive results needed to flip state. Failing over takes 3 misses
	// in a row (ordinary packet loss causes 2-miss blips); coming back takes
	// 2 good checks. Calls that actually drop don't wait for this: they ask
	// for an immediate check (CheckNow).
	turnProbeFailAfter    = 3
	turnProbeRecoverAfter = 2
	checkNowReuse         = 5 * time.Second
)

// NewTURNHealth probes addr (host:port, UDP) and, if statusURL is set, the
// turnload agent there. It starts healthy.
func NewTURNHealth(addr, statusURL string) *TURNHealth {
	return &TURNHealth{addr: addr, statusURL: statusURL, client: &http.Client{Timeout: turnProbeTimeout}}
}

// check is one probe: coturn must answer STUN and the agent mustn't report
// overload. An unreachable agent alone doesn't fail over (the STUN answer
// already shows coturn is up); during a flood both stop answering anyway.
func (h *TURNHealth) check() (ok bool, why string) {
	if err := stunProbe(h.addr, turnProbeTimeout); err != nil {
		return false, "not answering STUN"
	}
	if h.statusURL == "" {
		return true, ""
	}
	resp, err := h.client.Get(h.statusURL)
	if err != nil {
		return true, ""
	}
	defer resp.Body.Close()
	var st struct {
		Overloaded bool   `json:"overloaded"`
		Reason     string `json:"reason"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&st) != nil {
		return true, ""
	}
	if st.Overloaded {
		return false, "overloaded: " + st.Reason
	}
	return true, ""
}

// Healthy reports the last settled probe state.
func (h *TURNHealth) Healthy() bool { return !h.unhealthy.Load() }

// Run probes until ctx is cancelled.
func (h *TURNHealth) Run(ctx context.Context) {
	streak := 0 // results in a row that disagree with the current state
	t := time.NewTicker(turnProbeInterval)
	defer t.Stop()
	for {
		ok, why := h.check()
		need := turnProbeFailAfter
		if ok {
			need = turnProbeRecoverAfter
		}
		if ok == h.Healthy() {
			streak = 0
		} else if streak++; streak >= need {
			streak = 0
			h.unhealthy.Store(!ok)
			if ok {
				slog.Warn("turn: our TURN healthy again; new calls use it", "addr", h.addr)
			} else {
				slog.Warn("turn: new calls fail over to Cloudflare TURN", "addr", h.addr, "why", why)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// CheckNow probes coturn right away (or reuses a probe from the last few
// seconds) and returns whether it's usable. A failed check also marks it
// unhealthy at once, so other calls stop being sent to it; the background
// prober brings it back after two good checks.
func (h *TURNHealth) CheckNow() bool {
	h.checkMu.Lock()
	defer h.checkMu.Unlock()
	if time.Since(h.lastCheckAt) < checkNowReuse {
		return h.lastCheckOK
	}
	ok, why := h.check()
	h.lastCheckAt, h.lastCheckOK = time.Now(), ok
	if !ok && h.Healthy() {
		h.unhealthy.Store(true)
		slog.Warn("turn: a call reported its relay failed and our TURN isn't answering; failing over now",
			"addr", h.addr, "why", why)
	}
	return ok
}

// stunProbe sends a STUN Binding Request (RFC 5389) and waits for the
// matching success response.
func stunProbe(addr string, timeout time.Duration) error {
	conn, err := net.DialTimeout("udp", addr, timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	req := make([]byte, 20)
	binary.BigEndian.PutUint16(req[0:], 0x0001)     // Binding Request
	binary.BigEndian.PutUint32(req[4:], 0x2112A442) // magic cookie
	if _, err := rand.Read(req[8:20]); err != nil {
		return err
	}
	_ = conn.SetDeadline(time.Now().Add(timeout))
	if _, err := conn.Write(req); err != nil {
		return err
	}
	buf := make([]byte, 1500)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			return err
		}
		if n >= 20 && binary.BigEndian.Uint16(buf[0:]) == 0x0101 && bytes.Equal(buf[8:20], req[8:20]) {
			return nil
		}
	}
}

// CloudflareTURN mints short-lived credentials for Cloudflare Realtime TURN.
// The request carries nothing about the user, only the TTL.
type CloudflareTURN struct {
	KeyID    string
	APIToken string
	Client   *http.Client
	// Endpoint overrides the API base (tests). Empty = Cloudflare.
	Endpoint string
}

func (c *CloudflareTURN) generate(ctx context.Context, ttl int) (iceServer, error) {
	base := c.Endpoint
	if base == "" {
		base = "https://rtc.live.cloudflare.com"
	}
	url := fmt.Sprintf("%s/v1/turn/keys/%s/credentials/generate-ice-servers", base, c.KeyID)
	body, _ := json.Marshal(map[string]int{"ttl": ttl})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return iceServer{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.APIToken)
	req.Header.Set("Content-Type", "application/json")
	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return iceServer{}, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return iceServer{}, err
	}
	if resp.StatusCode/100 != 2 {
		return iceServer{}, fmt.Errorf("cloudflare turn: HTTP %d", resp.StatusCode)
	}
	return parseCloudflareICE(raw)
}

// parseCloudflareICE accepts both response shapes Cloudflare has used
// (iceServers as a list or a single object) and keeps only turn:/turns: URLs.
// Cloudflare's STUN would show callers' IPs to Cloudflare for nothing.
func parseCloudflareICE(raw []byte) (iceServer, error) {
	var env struct {
		ICEServers json.RawMessage `json:"iceServers"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return iceServer{}, err
	}
	var list []iceServer
	if err := json.Unmarshal(env.ICEServers, &list); err != nil {
		var one iceServer
		if err := json.Unmarshal(env.ICEServers, &one); err != nil {
			return iceServer{}, errors.New("cloudflare turn: unexpected response")
		}
		list = []iceServer{one}
	}
	for _, s := range list {
		var turn []string
		for _, u := range s.URLs {
			if strings.HasPrefix(u, "turn:") || strings.HasPrefix(u, "turns:") {
				turn = append(turn, u)
			}
		}
		if len(turn) > 0 && s.Username != "" && s.Credential != "" {
			return iceServer{URLs: turn, Username: s.Username, Credential: s.Credential}, nil
		}
	}
	return iceServer{}, errors.New("cloudflare turn: no TURN server in response")
}

// SetTURNFailover enables failover to Cloudflare when health reports our coturn
// down. Either may be nil (then there's no failover).
func (s *Server) SetTURNFailover(health *TURNHealth, cf *CloudflareTURN) {
	s.turnHealth = health
	s.cfTURN = cf
}
