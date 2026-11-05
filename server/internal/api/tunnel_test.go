package api

import (
	"bytes"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/tunnel"
	"google.golang.org/protobuf/proto"
)

func enableTunnel(env *testEnv) *tunnel.Client {
	env.t.Helper()
	k, err := tunnel.LoadOrCreateKey(filepath.Join(env.t.TempDir(), "tunnel.key"))
	if err != nil {
		env.t.Fatal(err)
	}
	env.api.SetTunnel(k)
	c, err := tunnel.NewClient(k.PublicKey())
	if err != nil {
		env.t.Fatal(err)
	}
	return c
}

// innerOf turns a signed request into what the app tunnels.
func innerOf(req *http.Request, body []byte) *tunnel.Request {
	in := &tunnel.Request{Method: req.Method, Scheme: "https", Authority: "relay", Path: req.URL.RequestURI(), Body: body}
	for name, values := range req.Header {
		for _, v := range values {
			in.Header = append(in.Header, [2]string{strings.ToLower(name), v})
		}
	}
	return in
}

func (env *testEnv) tunnelDo(tc *tunnel.Client, in *tunnel.Request) *tunnel.Response {
	env.t.Helper()
	msg, pending, err := tc.Seal(in)
	if err != nil {
		env.t.Fatal(err)
	}
	resp, err := http.Post(env.srv.URL+"/v1/t", "message/ohttp-req", bytes.NewReader(msg))
	if err != nil {
		env.t.Fatal(err)
	}
	defer resp.Body.Close()
	sealed, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		env.t.Fatalf("outer status %d: %s", resp.StatusCode, sealed)
	}
	out, err := pending.Open(sealed)
	if err != nil {
		env.t.Fatal(err)
	}
	return out
}

func TestTunnelRequests(t *testing.T) {
	env := newTestEnv(t)
	tc := enableTunnel(env)
	enableHistory(env, nil)
	c := env.register("tunnel-user", "password-tunnel")

	// A signed write and read, as the app sends them.
	body := []byte("segment through the tunnel")
	put, _ := http.NewRequest("PUT", env.srv.URL+"/v1/history/1001", bytes.NewReader(body))
	put.Header.Set("Content-Type", "application/octet-stream")
	c.sign(put, body)
	if r := env.tunnelDo(tc, innerOf(put, body)); r.Status != http.StatusNoContent {
		t.Fatalf("tunnelled PUT: %d %s", r.Status, r.Body)
	}
	get := c.signedRequest("GET", "/v1/history/1001", randomNonce(t), time.Now().UnixMilli())
	if r := env.tunnelDo(tc, innerOf(get, nil)); r.Status != http.StatusOK || !bytes.Equal(r.Body, body) {
		t.Fatalf("tunnelled GET: %d %q", r.Status, r.Body)
	}

	// The same signature can't be replayed through the tunnel.
	if r := env.tunnelDo(tc, innerOf(get, nil)); r.Status != http.StatusUnauthorized {
		t.Fatalf("replayed signature: %d", r.Status)
	}
	// Errors come back inside, with their status.
	if r := env.tunnelDo(tc, &tunnel.Request{Method: "GET", Path: "/v1/history"}); r.Status != http.StatusUnauthorized {
		t.Fatalf("unsigned: %d", r.Status)
	}
	// Forwarded-address headers inside are ignored, not trusted.
	ping := &tunnel.Request{Method: "GET", Path: "/v1/ping", Header: [][2]string{{"cf-connecting-ip", "203.0.113.9"}}}
	if r := env.tunnelDo(tc, ping); r.Status != http.StatusNoContent {
		t.Fatalf("ping: %d", r.Status)
	}
	// No nesting, no WebSocket over POST.
	for _, path := range []string{"/v1/t", "/v1/t/ws", "/v1/t?x=1", "/elsewhere"} {
		if r := env.tunnelDo(tc, &tunnel.Request{Method: "GET", Path: path}); r.Status != http.StatusBadRequest {
			t.Errorf("%s: %d", path, r.Status)
		}
	}
	// Routes that only start with "/v1/t" still go through: TURN credentials
	// (404 here because the test relay has no TURN configured, not 400).
	turn := c.signedRequest("GET", "/v1/turn-credentials", randomNonce(t), time.Now().UnixMilli())
	if r := env.tunnelDo(tc, innerOf(turn, nil)); r.Status != http.StatusNotFound {
		t.Fatalf("tunnelled turn-credentials: %d %s", r.Status, r.Body)
	}
	// Garbage outside gets a plain 400.
	resp, err := http.Post(env.srv.URL+"/v1/t", "message/ohttp-req", strings.NewReader("not a message"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("garbage: %d", resp.StatusCode)
	}
}

func TestTunnelWebSocket(t *testing.T) {
	env := newTestEnv(t)
	tc := enableTunnel(env)
	alice := env.register("tunnel-ws-a", "password-a")
	bob := env.register("tunnel-ws-b", "password-b")
	bob.uploadKeys(1)

	open := func(c *client, signed bool) (*websocket.Conn, *tunnel.Response, *tunnel.ClientStream) {
		t.Helper()
		conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(env.srv.URL, "http")+"/v1/t/ws", nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		probe, _ := http.NewRequest("GET", env.srv.URL+"/v1/ws", nil)
		if signed {
			c.sign(probe, nil)
		}
		msg, pending, err := tc.Seal(innerOf(probe, nil))
		if err != nil {
			t.Fatal(err)
		}
		conn.WriteMessage(websocket.BinaryMessage, msg) //nolint:errcheck
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, sealed, err := conn.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		resp, err := pending.Open(sealed)
		if err != nil {
			t.Fatal(err)
		}
		stream, _ := pending.Stream()
		return conn, resp, stream
	}
	read := func(conn *websocket.Conn, s *tunnel.ClientStream) *relaypb.ServerFrame {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, data, err := conn.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		plain, err := s.Open(data)
		if err != nil {
			t.Fatal(err)
		}
		f := &relaypb.ServerFrame{}
		if err := proto.Unmarshal(plain, f); err != nil {
			t.Fatal(err)
		}
		return f
	}

	if _, resp, _ := open(alice, false); resp.Status != http.StatusUnauthorized {
		t.Fatalf("unsigned open: %d", resp.Status)
	}

	bconn, resp, bs := open(bob, true)
	if resp.Status != http.StatusOK {
		t.Fatalf("open: %d %s", resp.Status, resp.Body)
	}
	if f := read(bconn, bs); f.GetQueueEmpty() == nil {
		t.Fatalf("first frame: %v", f)
	}

	aconn, resp, as := open(alice, true)
	if resp.Status != http.StatusOK {
		t.Fatalf("alice open: %d", resp.Status)
	}
	if f := read(aconn, as); f.GetQueueEmpty() == nil {
		t.Fatalf("alice first frame: %v", f)
	}
	frame, _ := proto.Marshal(sendFrame(bob.mailboxID, &relaypb.DeviceMessage{
		DeviceId:       1,
		RegistrationId: 4242,
		Type:           relaypb.CiphertextType_CIPHERTEXT_TYPE_PREKEY_MESSAGE,
		Content:        []byte("hi bob"),
	}))
	aconn.WriteMessage(websocket.BinaryMessage, as.Seal(frame)) //nolint:errcheck
	if f := read(aconn, as); f.GetSendResponse().GetStatus() != relaypb.SendStatus_SEND_STATUS_OK {
		t.Fatalf("send response: %v", f)
	}
	if f := read(bconn, bs); string(f.GetEnvelope().GetContent()) != "hi bob" {
		t.Fatalf("bob got: %v", f)
	}
}
