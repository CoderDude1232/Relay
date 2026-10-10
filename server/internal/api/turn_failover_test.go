package api

import (
	"encoding/binary"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParseCloudflareICE(t *testing.T) {
	list := `{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},
		{"urls":["turn:turn.cloudflare.com:3478?transport=udp","stun:x","turns:turn.cloudflare.com:443?transport=tcp"],
		 "username":"u","credential":"c"}]}`
	got, err := parseCloudflareICE([]byte(list))
	if err != nil || got.Username != "u" || got.Credential != "c" || len(got.URLs) != 2 {
		t.Fatalf("list shape: %+v %v", got, err)
	}
	for _, u := range got.URLs {
		if u[:4] == "stun" {
			t.Fatalf("STUN URL kept: %v", got.URLs)
		}
	}
	obj := `{"iceServers":{"urls":["turn:turn.cloudflare.com:3478"],"username":"u","credential":"c"}}`
	if got, err := parseCloudflareICE([]byte(obj)); err != nil || len(got.URLs) != 1 {
		t.Fatalf("object shape: %+v %v", got, err)
	}
	if _, err := parseCloudflareICE([]byte(`{"iceServers":[{"urls":["stun:x"]}]}`)); err == nil {
		t.Fatal("expected error with no TURN server")
	}
}

// stunStub answers STUN Binding Requests like coturn.
func stunStub(t *testing.T) string {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		buf := make([]byte, 1500)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			if n < 20 {
				continue
			}
			resp := make([]byte, 20)
			binary.BigEndian.PutUint16(resp[0:], 0x0101)
			copy(resp[4:20], buf[4:20])
			pc.WriteTo(resp, addr)
		}
	}()
	return pc.LocalAddr().String()
}

func TestTURNHealthCheck(t *testing.T) {
	addr := stunStub(t)
	overloaded := false
	agent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"overloaded": overloaded, "reason": "inbound 900 Mbps"})
	}))
	defer agent.Close()

	h := NewTURNHealth(addr, agent.URL)
	if ok, why := h.check(); !ok {
		t.Fatalf("healthy coturn reported down: %s", why)
	}
	overloaded = true
	if ok, _ := h.check(); ok {
		t.Fatal("overloaded agent not reported")
	}
	// Agent unreachable but coturn answering: stay on coturn.
	h2 := NewTURNHealth(addr, "http://127.0.0.1:1/status")
	if ok, _ := h2.check(); !ok {
		t.Fatal("unreachable agent alone should not fail over")
	}
	// Coturn silent: fail over.
	dead, _ := net.ListenPacket("udp", "127.0.0.1:0")
	deadAddr := dead.LocalAddr().String()
	dead.Close()
	if err := stunProbe(deadAddr, 300*time.Millisecond); err == nil {
		t.Fatal("probe of a closed port succeeded")
	}
}

func TestTurnCredentialsFailover(t *testing.T) {
	cf := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" || r.URL.Path != "/v1/turn/keys/kid/credentials/generate-ice-servers" {
			http.Error(w, "bad", http.StatusUnauthorized)
			return
		}
		w.Write([]byte(`{"iceServers":[{"urls":["turns:turn.cloudflare.com:443?transport=tcp"],"username":"cfu","credential":"cfc"}]}`))
	}))
	defer cf.Close()

	s := &Server{turnURLs: []string{"turn:turn.example:3478"}, turnSecret: "secret"}
	health := NewTURNHealth("127.0.0.1:1", "")
	s.SetTURNFailover(health, &CloudflareTURN{KeyID: "kid", APIToken: "tok", Endpoint: cf.URL})

	type resp struct {
		URLs       []string    `json:"urls"`
		Username   string      `json:"username"`
		ICEServers []iceServer `json:"iceServers"`
	}
	get := func() resp {
		w := httptest.NewRecorder()
		s.handleTurnCredentials(w, httptest.NewRequest("GET", "/v1/turn-credentials", nil), nil)
		var r resp
		if err := json.Unmarshal(w.Body.Bytes(), &r); err != nil {
			t.Fatal(err)
		}
		return r
	}

	r := get()
	if len(r.ICEServers) != 1 || r.ICEServers[0].URLs[0] != "turn:turn.example:3478" || r.URLs[0] != "turn:turn.example:3478" {
		t.Fatalf("healthy: Cloudflare must not be handed out: %+v", r)
	}

	health.unhealthy.Store(true)
	r = get()
	if len(r.ICEServers) != 1 || r.ICEServers[0].Username != "cfu" || r.Username != "cfu" {
		t.Fatalf("unhealthy: only Cloudflare should be handed out (and in legacy fields): %+v", r)
	}

	// Cloudflare failing: still hand out our own server.
	s.cfTURN.APIToken = "wrong"
	r = get()
	if len(r.ICEServers) != 1 || r.URLs[0] != "turn:turn.example:3478" {
		t.Fatalf("cloudflare down: should fall back to own TURN: %+v", r)
	}
}

func TestCheckNowFailsOverImmediately(t *testing.T) {
	cf := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"iceServers":[{"urls":["turns:turn.cloudflare.com:443?transport=tcp"],"username":"cfu","credential":"cfc"}]}`))
	}))
	defer cf.Close()

	// Our TURN "answers": a failed=1 report must NOT hand out Cloudflare.
	live := NewTURNHealth(stunStub(t), "")
	s := &Server{turnURLs: []string{"turn:turn.example:3478"}, turnSecret: "secret"}
	s.SetTURNFailover(live, &CloudflareTURN{KeyID: "kid", APIToken: "tok", Endpoint: cf.URL})
	get := func(q string) string {
		w := httptest.NewRecorder()
		s.handleTurnCredentials(w, httptest.NewRequest("GET", "/v1/turn-credentials"+q, nil), nil)
		var r struct {
			Username string `json:"username"`
		}
		json.Unmarshal(w.Body.Bytes(), &r)
		return r.Username
	}
	if u := get("?failed=1"); u == "cfu" {
		t.Fatal("handed out Cloudflare although our TURN answers")
	}

	// Our TURN silent: failed=1 hands out Cloudflare at once and marks it unhealthy.
	dead, _ := net.ListenPacket("udp", "127.0.0.1:0")
	deadAddr := dead.LocalAddr().String()
	dead.Close()
	down := NewTURNHealth(deadAddr, "")
	s.SetTURNFailover(down, &CloudflareTURN{KeyID: "kid", APIToken: "tok", Endpoint: cf.URL})
	if u := get(""); u == "cfu" {
		t.Fatal("plain request should still get our TURN until the prober notices")
	}
	if u := get("?failed=1"); u != "cfu" {
		t.Fatalf("failed=1 with our TURN down should give Cloudflare, got %q", u)
	}
	if down.Healthy() {
		t.Fatal("failed check should mark our TURN unhealthy")
	}
	if u := get(""); u != "cfu" {
		t.Fatal("after the failed check, every call should get Cloudflare")
	}
}
