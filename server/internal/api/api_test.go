package api

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/blob"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/store"
	"google.golang.org/protobuf/proto"
)

type testEnv struct {
	t   *testing.T
	srv *httptest.Server
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	dsn := os.Getenv("RELAY_TEST_DSN")
	if dsn == "" {
		t.Skip("set RELAY_TEST_DSN to run Postgres-backed API integration tests")
	}
	st, err := store.Open(dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	blobs, err := blob.Open(filepath.Join(t.TempDir(), "blobs"), 25<<20)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(New(st, hub.New(st), blobs, "", "").Handler())
	t.Cleanup(srv.Close)
	return &testEnv{t: t, srv: srv}
}

type client struct {
	env       *testEnv
	accountID string
	deviceID  uint32
	password  string
	authKey   *ecdsa.PrivateKey
}

func (e *testEnv) register(username, password string) *client {
	e.t.Helper()
	var resp struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
	}
	e.doJSON("POST", "/v1/accounts", "", "", map[string]string{"username": username, "password": password}, http.StatusCreated, &resp)
	c := &client{env: e, accountID: resp.AccountID, deviceID: resp.DeviceID, password: password}
	c.uploadDeviceAuthKey()
	return c
}

func (e *testEnv) doJSON(method, path, user, pass string, body any, wantStatus int, out any) {
	e.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, err := http.NewRequest(method, e.srv.URL+path, &buf)
	if err != nil {
		e.t.Fatal(err)
	}
	if user != "" {
		req.SetBasicAuth(user, pass)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != wantStatus {
		e.t.Fatalf("%s %s: got status %d, want %d", method, path, resp.StatusCode, wantStatus)
	}
	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			e.t.Fatal(err)
		}
	}
}

func (c *client) authUser() string { return fmt.Sprintf("%s.%d", c.accountID, c.deviceID) }

func (c *client) uploadDeviceAuthKey() {
	c.env.t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		c.env.t.Fatal(err)
	}
	c.authKey = key
	c.env.doJSON("PUT", "/v1/devices/auth-key", c.authUser(), c.password, map[string]string{
		"publicKey": base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), key.X, key.Y)),
	}, http.StatusNoContent, nil)
}

func (c *client) deviceListVersion() int64 {
	c.env.t.Helper()
	var resp struct {
		DeviceListVersion int64 `json:"deviceListVersion"`
	}
	c.env.doJSON("GET", "/v1/devices", c.authUser(), c.password, nil, http.StatusOK, &resp)
	return resp.DeviceListVersion
}

func (c *client) signedDeviceMutation(action string, target uint32, password string) map[string]any {
	c.env.t.Helper()
	version := c.deviceListVersion()
	payload := deviceMutationPayload(c.accountID, version, action, target, password)
	digest := sha256.Sum256([]byte(payload))
	signature, err := ecdsa.SignASN1(rand.Reader, c.authKey, digest[:])
	if err != nil {
		c.env.t.Fatal(err)
	}
	return map[string]any{
		"expectedVersion": version,
		"signerDeviceId":  c.deviceID,
		"signature":       base64.StdEncoding.EncodeToString(signature),
	}
}

func (c *client) uploadKeys(numOneTime int) {
	c.env.t.Helper()
	otks := make([]map[string]any, numOneTime)
	for i := range otks {
		otks[i] = map[string]any{"keyId": i + 1, "publicKey": "b3RrLXB1YmxpYw=="}
	}
	c.env.doJSON("PUT", "/v1/keys", c.authUser(), c.password, map[string]any{
		"registrationId": 4242,
		"identityKey":    "aWRlbnRpdHkta2V5",
		"signedPreKey":   map[string]any{"keyId": 1, "publicKey": "c3BrLXB1YmxpYw==", "signature": "c2ln"},
		"kyberPreKey":    map[string]any{"keyId": 1, "publicKey": "a3liZXItcHVibGlj", "signature": "a3liZXItc2ln"},
		"oneTimePreKeys": otks,
	}, http.StatusNoContent, nil)
}

func (c *client) keyCount() int {
	c.env.t.Helper()
	var resp struct {
		Count int `json:"count"`
	}
	c.env.doJSON("GET", "/v1/keys/count", c.authUser(), c.password, nil, http.StatusOK, &resp)
	return resp.Count
}

// wsConn wraps a WebSocket connection and reads until the initial offline
// queue has been drained.
type wsConn struct {
	t    *testing.T
	conn *websocket.Conn
	// envelopes received while draining the offline queue
	queued []*relaypb.Envelope
}

func (c *client) connectWS() *wsConn {
	c.env.t.Helper()
	url := "ws" + strings.TrimPrefix(c.env.srv.URL, "http") + "/v1/ws"
	hdr := http.Header{}
	hdr.Set("Authorization", "Basic "+basicAuth(c.authUser(), c.password))
	conn, _, err := websocket.DefaultDialer.Dial(url, hdr)
	if err != nil {
		c.env.t.Fatal(err)
	}
	c.env.t.Cleanup(func() { conn.Close() })

	w := &wsConn{t: c.env.t, conn: conn}
	for {
		frame := w.readFrame()
		switch p := frame.Payload.(type) {
		case *relaypb.ServerFrame_Envelope:
			w.queued = append(w.queued, p.Envelope)
		case *relaypb.ServerFrame_QueueEmpty:
			return w
		default:
			c.env.t.Fatalf("unexpected frame during drain: %T", p)
		}
	}
}

func basicAuth(user, pass string) string {
	req, _ := http.NewRequest("GET", "http://x", nil)
	req.SetBasicAuth(user, pass)
	return strings.TrimPrefix(req.Header.Get("Authorization"), "Basic ")
}

func (w *wsConn) readFrame() *relaypb.ServerFrame {
	w.t.Helper()
	w.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, data, err := w.conn.ReadMessage()
	if err != nil {
		w.t.Fatalf("ws read: %v", err)
	}
	frame := &relaypb.ServerFrame{}
	if err := proto.Unmarshal(data, frame); err != nil {
		w.t.Fatal(err)
	}
	return frame
}

func (w *wsConn) writeFrame(frame *relaypb.ClientFrame) {
	w.t.Helper()
	data, err := proto.Marshal(frame)
	if err != nil {
		w.t.Fatal(err)
	}
	w.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if err := w.conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		w.t.Fatal(err)
	}
}

func sendFrame(dest string, msgs ...*relaypb.DeviceMessage) *relaypb.ClientFrame {
	return &relaypb.ClientFrame{
		Id: 1,
		Payload: &relaypb.ClientFrame_Send{Send: &relaypb.SendRequest{
			DestinationAccount: dest,
			Messages:           msgs,
			ClientTimestamp:    time.Now().UnixMilli(),
		}},
	}
}

// ---------------------------------------------------------------------------

func TestVerifyDeviceMutation(t *testing.T) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	payload := deviceMutationPayload("account-1", 7, "remove", 2, "")
	digest := sha256.Sum256([]byte(payload))
	signature, err := ecdsa.SignASN1(rand.Reader, privateKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	dev := &store.Device{
		AccountID:     "account-1",
		DeviceID:      1,
		AuthPublicKey: elliptic.Marshal(elliptic.P256(), privateKey.X, privateKey.Y),
	}
	auth := deviceMutationAuth{
		ExpectedVersion: 7,
		SignerDeviceID:  1,
		Signature:       signature,
	}
	if err := verifyDeviceMutation(dev, auth, "remove", 2, ""); err != nil {
		t.Fatalf("valid signature rejected: %v", err)
	}
	if err := verifyDeviceMutation(dev, auth, "remove", 3, ""); err == nil {
		t.Fatal("signature accepted for different target device")
	}
}

func TestPreKeyBundleConsumption(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("alice", "password-alice")
	bob := env.register("bob", "password-bob")
	bob.uploadKeys(2)

	if got := bob.keyCount(); got != 2 {
		t.Fatalf("key count = %d, want 2", got)
	}

	var bundle struct {
		Devices []struct {
			DeviceID    uint32 `json:"deviceId"`
			KyberPreKey struct {
				PublicKey string `json:"publicKey"`
			} `json:"kyberPreKey"`
			OneTimePreKey *struct {
				KeyID uint32 `json:"keyId"`
			} `json:"oneTimePreKey"`
		} `json:"devices"`
	}
	// First two fetches consume the pool; the third succeeds degraded.
	for i := 0; i < 2; i++ {
		env.doJSON("GET", "/v1/keys/"+bob.accountID, alice.authUser(), alice.password, nil, http.StatusOK, &bundle)
		if len(bundle.Devices) != 1 || bundle.Devices[0].OneTimePreKey == nil {
			t.Fatalf("fetch %d: expected a one-time prekey, got %+v", i, bundle)
		}
		if bundle.Devices[0].KyberPreKey.PublicKey == "" {
			t.Fatalf("fetch %d: bundle is missing the kyber prekey", i)
		}
	}
	env.doJSON("GET", "/v1/keys/"+bob.accountID, alice.authUser(), alice.password, nil, http.StatusOK, &bundle)
	if bundle.Devices[0].OneTimePreKey != nil {
		t.Fatal("expected degraded bundle (no one-time prekey) after pool exhaustion")
	}
	if got := bob.keyCount(); got != 0 {
		t.Fatalf("key count = %d, want 0", got)
	}
}

func TestSendReceiveAckAndOfflineQueue(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("alice", "password-alice")
	bob := env.register("bob", "password-bob")
	alice.uploadKeys(1)
	bob.uploadKeys(1)

	aliceWS := env.connect(alice)
	bobWS := env.connect(bob)

	// Alice sends to Bob while he is online.
	aliceWS.writeFrame(sendFrame(bob.accountID, &relaypb.DeviceMessage{
		DeviceId:       1,
		RegistrationId: 4242,
		Type:           relaypb.CiphertextType_CIPHERTEXT_TYPE_PREKEY_MESSAGE,
		Content:        []byte("ciphertext-1"),
	}))

	if resp := aliceWS.readFrame().GetSendResponse(); resp.GetStatus() != relaypb.SendStatus_SEND_STATUS_OK {
		t.Fatalf("send status = %v", resp.GetStatus())
	}
	env1 := bobWS.readFrame().GetEnvelope()
	if env1 == nil || string(env1.Content) != "ciphertext-1" || env1.SenderAccount != alice.accountID {
		t.Fatalf("bad envelope: %+v", env1)
	}

	// Bob acks; then disconnects; Alice sends while Bob is offline.
	bobWS.writeFrame(&relaypb.ClientFrame{Payload: &relaypb.ClientFrame_Ack{Ack: &relaypb.AckRequest{EnvelopeId: env1.Id}}})
	time.Sleep(100 * time.Millisecond) // let the ack land before disconnect
	bobWS.conn.Close()
	time.Sleep(100 * time.Millisecond) // let the hub unregister

	aliceWS.writeFrame(sendFrame(bob.accountID, &relaypb.DeviceMessage{
		DeviceId: 1,
		Type:     relaypb.CiphertextType_CIPHERTEXT_TYPE_MESSAGE,
		Content:  []byte("ciphertext-2"),
	}))
	if resp := aliceWS.readFrame().GetSendResponse(); resp.GetStatus() != relaypb.SendStatus_SEND_STATUS_OK {
		t.Fatalf("offline send status = %v", resp.GetStatus())
	}

	// Bob reconnects: exactly the unacked envelope is drained from the queue.
	bobWS2 := env.connect(bob)
	if len(bobWS2.queued) != 1 || string(bobWS2.queued[0].Content) != "ciphertext-2" {
		t.Fatalf("queued after reconnect = %+v, want just ciphertext-2", bobWS2.queued)
	}
}

func TestMismatchedDevicesRejected(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("alice", "password-alice")
	bob := env.register("bob", "password-bob")
	bob.uploadKeys(1)

	// Bob adds a second device; Alice only encrypts for device 1.
	secondDevicePassword := "password-bob2"
	env.doJSON("POST", "/v1/devices", bob.authUser(), bob.password, map[string]any{
		"password": secondDevicePassword,
		"auth":     bob.signedDeviceMutation("add", 0, secondDevicePassword),
	}, http.StatusCreated, nil)

	aliceWS := env.connect(alice)
	aliceWS.writeFrame(sendFrame(bob.accountID, &relaypb.DeviceMessage{
		DeviceId: 1,
		Type:     relaypb.CiphertextType_CIPHERTEXT_TYPE_MESSAGE,
		Content:  []byte("x"),
	}))
	resp := aliceWS.readFrame().GetSendResponse()
	if resp.GetStatus() != relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES {
		t.Fatalf("status = %v, want MISMATCHED_DEVICES", resp.GetStatus())
	}
	if len(resp.MissingDevices) != 1 || resp.MissingDevices[0] != 2 {
		t.Fatalf("missing devices = %v, want [2]", resp.MissingDevices)
	}

	// Stale registration id is also rejected.
	aliceWS.writeFrame(sendFrame(bob.accountID,
		&relaypb.DeviceMessage{DeviceId: 1, RegistrationId: 9999, Content: []byte("x")},
		&relaypb.DeviceMessage{DeviceId: 2, Content: []byte("x")},
	))
	resp = aliceWS.readFrame().GetSendResponse()
	if resp.GetStatus() != relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES || len(resp.StaleDevices) != 1 {
		t.Fatalf("stale check: %+v", resp)
	}
}

func (e *testEnv) connect(c *client) *wsConn { return c.connectWS() }

func TestGroupLifecycle(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("alice", "password123")
	bob := env.register("bob", "password123")
	carol := env.register("carol", "password123")

	// Alice creates a group with Bob.
	var g struct {
		ID             string   `json:"id"`
		Name           string   `json:"name"`
		DistributionID string   `json:"distributionId"`
		Revision       int64    `json:"revision"`
		Members        []string `json:"members"`
	}
	env.doJSON("POST", "/v1/groups", alice.authUser(), alice.password,
		map[string]any{"name": "Trip", "members": []string{bob.accountID}}, http.StatusCreated, &g)
	if len(g.Members) != 2 || g.Revision != 1 || g.DistributionID == "" {
		t.Fatalf("unexpected group: %+v", g)
	}

	// Bob (a member) can fetch; Carol (not a member) is forbidden.
	env.doJSON("GET", "/v1/groups/"+g.ID, bob.authUser(), bob.password, nil, http.StatusOK, nil)
	env.doJSON("GET", "/v1/groups/"+g.ID, carol.authUser(), carol.password, nil, http.StatusForbidden, nil)

	// Add Carol → revision bumps, distribution id unchanged (no rotation on add).
	var afterAdd struct {
		DistributionID string `json:"distributionId"`
		Revision       int64  `json:"revision"`
		Members        []string `json:"members"`
	}
	env.doJSON("POST", "/v1/groups/"+g.ID+"/members", alice.authUser(), alice.password,
		map[string]string{"account": carol.accountID}, http.StatusOK, &afterAdd)
	if len(afterAdd.Members) != 3 || afterAdd.Revision != 2 || afterAdd.DistributionID != g.DistributionID {
		t.Fatalf("add changed distribution id or wrong revision: %+v", afterAdd)
	}

	// Remove Carol → rotation: distribution id changes, revision bumps.
	var afterRemove struct {
		DistributionID string   `json:"distributionId"`
		Revision       int64    `json:"revision"`
		Members        []string `json:"members"`
	}
	env.doJSON("DELETE", "/v1/groups/"+g.ID+"/members/"+carol.accountID, alice.authUser(), alice.password,
		nil, http.StatusOK, &afterRemove)
	if len(afterRemove.Members) != 2 || afterRemove.Revision != 3 || afterRemove.DistributionID == g.DistributionID {
		t.Fatalf("remove did not rotate distribution id: %+v", afterRemove)
	}
}
