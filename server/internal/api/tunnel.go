package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/relayapp/relay-server/internal/store"
	"github.com/relayapp/relay-server/internal/tunnel"
)

// The encrypted tunnel (internal/tunnel, docs/TUNNEL.md): the app sends each
// request as POST /v1/t, an Oblivious HTTP message to relayd's tunnel key, and
// holds its WebSocket on /v1/t/ws, so Cloudflare sees padded sizes and timing
// but no paths, account ids, signatures or mailboxes. The decrypted request
// runs through the same handlers as a direct one, with the outer request's
// source address for rate limits.

const (
	// Bodies past this go direct (large attachments); the app checks first.
	maxTunnelBody = 8 << 20
	// The outer message: a full inner body, its encoding and padding, and the
	// encapsulation.
	maxTunnelMessage = maxTunnelBody + 128<<10
	tunnelIOTimeout  = 3 * time.Minute
	// How long a tunnelled WebSocket has to send its opening request.
	tunnelOpenTimeout = 15 * time.Second
)

// Headers a tunnelled request may carry; the rest (forwarded addresses
// included) are dropped.
var tunnelRequestHeaders = map[string]bool{
	"authorization":          true,
	"content-type":           true,
	"relay-access-key":       true,
	"x-relay-timestamp":      true,
	"x-relay-nonce":          true,
	"x-relay-content-sha256": true,
}

// And the response headers the app reads.
var tunnelResponseHeaders = []string{"Content-Type", "Retry-After"}

// SetTunnel enables /v1/t and /v1/t/ws with k.
func (s *Server) SetTunnel(k *tunnel.Key) { s.tunnelKey = k }

// tunnelRoutes handles the tunnel's own paths and passes everything else on.
func (s *Server) tunnelRoutes(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/t" && r.Method == http.MethodPost && s.tunnelKey != nil:
			s.handleTunnel(w, r, next)
		case r.URL.Path == "/v1/t/ws" && r.Method == http.MethodGet && s.tunnelKey != nil:
			s.handleTunnelWebSocket(w, r)
		case r.URL.Path == "/v1/t/key" && r.Method == http.MethodGet && s.tunnelKey != nil:
			writeJSON(w, http.StatusOK, map[string]any{
				"keyId": tunnel.KeyID, "publicKey": base64.StdEncoding.EncodeToString(s.tunnelKey.PublicKey()),
			})
		default:
			next.ServeHTTP(w, r)
		}
	})
}

// innerRequest rebuilds the decrypted request for the handlers.
func innerRequest(ctx context.Context, outer *http.Request, in *tunnel.Request) (*http.Request, bool) {
	if !strings.HasPrefix(in.Path, "/v1/") || strings.HasPrefix(in.Path, "/v1/t") || len(in.Body) > maxTunnelBody {
		return nil, false
	}
	u, err := url.ParseRequestURI(in.Path)
	if err != nil {
		return nil, false
	}
	switch in.Method {
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch:
	default:
		return nil, false
	}
	r, err := http.NewRequestWithContext(ctx, in.Method, u.String(), bytes.NewReader(in.Body))
	if err != nil {
		return nil, false
	}
	r.URL = u
	r.RequestURI = in.Path
	r.Host = outer.Host
	r.RemoteAddr = outer.RemoteAddr
	r.ContentLength = int64(len(in.Body))
	for _, f := range in.Header {
		if tunnelRequestHeaders[f[0]] {
			r.Header.Add(f[0], f[1])
		}
	}
	return r, true
}

// POST /v1/t: an encapsulated request → 200 with the encapsulated response,
// whatever the inner status. 400 only when the message doesn't decrypt.
func (s *Server) handleTunnel(w http.ResponseWriter, r *http.Request, next http.Handler) {
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(tunnelIOTimeout))
	_ = rc.SetWriteDeadline(time.Now().Add(tunnelIOTimeout))
	msg, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxTunnelMessage))
	if err != nil {
		httpError(w, http.StatusRequestEntityTooLarge, "tunnel message too large")
		return
	}
	opened, err := s.tunnelKey.Open(msg)
	if err != nil {
		httpError(w, http.StatusBadRequest, "tunnel message didn't decrypt")
		return
	}
	resp := &tunnel.Response{Status: http.StatusBadRequest, Body: []byte(`{"error":"bad tunnelled request"}`)}
	if inner, ok := innerRequest(r.Context(), r, opened.Request); ok {
		rec := newTunnelRecorder()
		next.ServeHTTP(rec, inner)
		resp = rec.response()
	}
	sealed, err := opened.Seal(resp)
	if err != nil {
		internalError(w, err)
		return
	}
	w.Header().Set("Content-Type", "message/ohttp-res")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	w.Write(sealed) //nolint:errcheck
}

// tunnelRecorder buffers an inner response, up to maxTunnelBody.
type tunnelRecorder struct {
	header   http.Header
	status   int
	body     bytes.Buffer
	tooLarge bool
}

func newTunnelRecorder() *tunnelRecorder { return &tunnelRecorder{header: http.Header{}} }

func (t *tunnelRecorder) Header() http.Header { return t.header }

func (t *tunnelRecorder) WriteHeader(status int) {
	if t.status == 0 {
		t.status = status
	}
}

func (t *tunnelRecorder) Write(b []byte) (int, error) {
	t.WriteHeader(http.StatusOK)
	if t.tooLarge || t.body.Len()+len(b) > maxTunnelBody {
		t.tooLarge = true
		t.body.Reset()
		return 0, io.ErrShortWrite
	}
	return t.body.Write(b)
}

func (t *tunnelRecorder) response() *tunnel.Response {
	if t.tooLarge {
		// The app fetches it directly instead.
		return &tunnel.Response{Status: http.StatusRequestEntityTooLarge,
			Header: [][2]string{{"x-relay-tunnel", "too-large"}},
			Body:   []byte(`{"error":"too large for the tunnel"}`)}
	}
	status := t.status
	if status == 0 {
		status = http.StatusOK
	}
	resp := &tunnel.Response{Status: status, Body: t.body.Bytes()}
	for _, name := range tunnelResponseHeaders {
		if v := t.header.Get(name); v != "" {
			resp.Header = append(resp.Header, [2]string{strings.ToLower(name), v})
		}
	}
	return resp
}

// GET /v1/t/ws: an unauthenticated upgrade. The first client message is an
// encapsulated, signed GET /v1/ws; the first server message the encapsulated
// answer (200, or the authentication error). After a 200 every frame is
// encrypted under keys exported from that exchange (tunnel.Stream).
func (s *Server) handleTunnelWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(maxTunnelMessage)
	conn.SetReadDeadline(time.Now().Add(tunnelOpenTimeout)) //nolint:errcheck
	msgType, msg, err := conn.ReadMessage()
	if err != nil || msgType != websocket.BinaryMessage {
		conn.Close()
		return
	}
	opened, err := s.tunnelKey.Open(msg)
	if err != nil {
		conn.Close()
		return
	}
	reply := func(resp *tunnel.Response) bool {
		sealed, err := opened.Seal(resp)
		if err != nil {
			return false
		}
		conn.SetWriteDeadline(time.Now().Add(writeWait)) //nolint:errcheck
		return conn.WriteMessage(websocket.BinaryMessage, sealed) == nil
	}
	inner, ok := innerRequest(r.Context(), r, opened.Request)
	if !ok || inner.Method != http.MethodGet || inner.URL.Path != webSocketUpgradePrefix {
		reply(&tunnel.Response{Status: http.StatusBadRequest, Body: []byte(`{"error":"expected GET /v1/ws"}`)})
		conn.Close()
		return
	}
	var dev *store.Device
	rec := newTunnelRecorder()
	s.auth(func(_ http.ResponseWriter, _ *http.Request, d *store.Device) { dev = d })(rec, inner)
	if dev == nil {
		reply(rec.response())
		conn.Close()
		return
	}
	stream, err := opened.Stream()
	if err != nil || !reply(&tunnel.Response{Status: http.StatusOK}) {
		conn.Close()
		return
	}
	s.serveWebSocket(&tunnelConn{Conn: conn, stream: stream}, dev)
}

// tunnelConn encrypts a session's data frames; pings, pongs and close frames
// carry nothing and pass through.
type tunnelConn struct {
	*websocket.Conn
	stream *tunnel.Stream
}

func (t *tunnelConn) WriteMessage(messageType int, data []byte) error {
	if messageType != websocket.BinaryMessage {
		return t.Conn.WriteMessage(messageType, data)
	}
	return t.Conn.WriteMessage(websocket.BinaryMessage, t.stream.Seal(data))
}

func (t *tunnelConn) ReadMessage() (int, []byte, error) {
	messageType, data, err := t.Conn.ReadMessage()
	if err != nil || messageType != websocket.BinaryMessage {
		return messageType, data, err
	}
	// A frame that doesn't open breaks the counter: end the session.
	frame, err := t.stream.Open(data)
	if err != nil {
		return 0, nil, err
	}
	return messageType, frame, nil
}

// SetReadLimit allows for the padding and tag around a frame of limit bytes.
func (t *tunnelConn) SetReadLimit(limit int64) {
	t.Conn.SetReadLimit(int64(tunnel.PaddedLen(int(limit)+4)) + 16)
}
