package api

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
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
	"github.com/gtank/ristretto255"
	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/blob"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/oprf"
	"github.com/relayapp/relay-server/internal/store"
	"google.golang.org/protobuf/proto"
)

type testEnv struct {
	t   *testing.T
	srv *httptest.Server
	api *Server
	// clients by "<accountID>.<deviceID>" so doJSON can sign requests for a
	// device that has registered an auth key (Basic is refused after that).
	clients map[string]*client
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
	apiServer := New(st, hub.New(st), blobs, "", "")
	srv := httptest.NewServer(apiServer.Handler())
	t.Cleanup(srv.Close)
	return &testEnv{t: t, srv: srv, api: apiServer, clients: map[string]*client{}}
}

type client struct {
	env       *testEnv
	username  string
	accountID string
	deviceID  uint32
	password  string
	authKey   *ecdsa.PrivateKey
}

// register creates an account whose username is prefix plus a random suffix,
// so tests sharing one database never collide (read it back from c.username).
func (e *testEnv) register(prefix, password string) *client {
	e.t.Helper()
	return e.registerAs(uniqueUsername(prefix), password)
}

// registerAs creates an account with exactly this username.
func (e *testEnv) registerAs(username, password string) *client {
	e.t.Helper()
	var resp struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
	}
	e.doJSON("POST", "/v1/accounts", "", "", map[string]string{"username": username, "password": password}, http.StatusCreated, &resp)
	c := &client{env: e, username: username, accountID: resp.AccountID, deviceID: resp.DeviceID, password: password}
	e.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()
	return c
}

func (e *testEnv) doJSON(method, path, user, pass string, body any, wantStatus int, out any) {
	e.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	bodyBytes := buf.Bytes()
	req, err := http.NewRequest(method, e.srv.URL+path, bytes.NewReader(bodyBytes))
	if err != nil {
		e.t.Fatal(err)
	}
	if user != "" {
		if c := e.clients[user]; c != nil && c.authKey != nil {
			c.sign(req, bodyBytes)
		} else {
			req.SetBasicAuth(user, pass)
		}
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
	// The first upload goes over Basic; only afterwards does the client sign
	// (signing with a key the relay doesn't hold yet is rightly refused).
	c.env.doJSON("PUT", "/v1/devices/auth-key", c.authUser(), c.password, map[string]string{
		"publicKey": base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), key.X, key.Y)),
	}, http.StatusNoContent, nil)
	c.authKey = key
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
	probe, _ := http.NewRequest("GET", c.env.srv.URL+"/v1/ws", nil)
	c.sign(probe, nil)
	conn, _, err := websocket.DefaultDialer.Dial(url, probe.Header)
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
		DistributionID string   `json:"distributionId"`
		Revision       int64    `json:"revision"`
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

// TestOAuthAccountProvisioning covers the social-login flow: first sign-in
// creates the account, a later sign-in from a "new device" (no local creds)
// recovers the same account (bumping the device list), an account registered
// with a confirmed email is adopted by email from another Supabase identity,
// and an UNconfirmed email never adopts anything.
func TestOAuthAccountProvisioning(t *testing.T) {
	env := newTestEnv(t)
	// Stub Supabase verification: the token is "userID|email"; user ids starting
	// with "nc-" have an unconfirmed email.
	env.api.SetSupabaseAuth("https://stub.supabase.co", "anon")
	// Emails are stored only as OPRF tokens, so linking needs a key.
	oprfKey, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(oprfKey); err != nil {
		t.Fatal(err)
	}
	env.api.verifySupabaseToken = func(_ context.Context, token string) (supabaseUser, error) {
		id, email, ok := strings.Cut(token, "|")
		if !ok || id == "" {
			return supabaseUser{}, fmt.Errorf("bad stub token")
		}
		return supabaseUser{ID: id, Email: email, EmailConfirmed: !strings.HasPrefix(id, "nc-")}, nil
	}
	sfx := uniqueUsername("")
	alice, bob := "alice"+sfx, "bob"+sfx
	u1, u2, u3 := "u1"+sfx, "u2"+sfx, "u3"+sfx
	emailA, emailB := "a"+sfx+"@x.com", "b"+sfx+"@x.com"

	type oauthResp struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
		Username  string `json:"username"`
		Created   bool   `json:"created"`
	}

	// Missing username on first sign-in → 404 (client should prompt).
	env.doJSON("POST", "/v1/accounts/oauth", "", "",
		map[string]string{"accessToken": u1 + "|" + emailA, "password": "device-pw-123"},
		http.StatusNotFound, nil)

	// First sign-in with a username → creates the account (201).
	var first oauthResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "",
		map[string]string{"accessToken": u1 + "|" + emailA, "username": alice, "password": "device-pw-123"},
		http.StatusCreated, &first)
	if !first.Created || first.Username != alice || first.DeviceID != 1 {
		t.Fatalf("first sign-in: %+v", first)
	}

	// Second sign-in from a fresh device (no username) → same account, new device.
	var second oauthResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "",
		map[string]string{"accessToken": u1 + "|" + emailA, "password": "device-pw-456"},
		http.StatusOK, &second)
	if second.Created || second.AccountID != first.AccountID || second.DeviceID != 2 {
		t.Fatalf("second sign-in did not recover account: %+v (first=%+v)", second, first)
	}

	// Registration never accepts a raw email.
	env.doJSON("POST", "/v1/accounts", "", "",
		map[string]string{"username": bob, "password": "bob-pw-1234", "email": emailB},
		http.StatusBadRequest, nil)
	// Register with a Supabase token whose email is confirmed → email linked.
	env.doJSON("POST", "/v1/accounts", "", "",
		map[string]string{"username": bob, "password": "bob-pw-1234", "supabaseAccessToken": u2 + "|" + emailB},
		http.StatusCreated, nil)

	// An unconfirmed email never adopts the account (no id match → username required).
	env.doJSON("POST", "/v1/accounts/oauth", "", "",
		map[string]string{"accessToken": "nc-" + u3 + "|" + emailB, "password": "device-pw-000"},
		http.StatusNotFound, nil)

	// Another Supabase identity with the same CONFIRMED email signs in to bob.
	var adopt oauthResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "",
		map[string]string{"accessToken": u3 + "|" + emailB, "password": "device-pw-789"},
		http.StatusOK, &adopt)
	if adopt.Created || adopt.Username != bob || adopt.DeviceID != 2 {
		t.Fatalf("email adoption failed: %+v", adopt)
	}
	// u2's sign-in still matches by its (kept) Supabase user id link.
	var again oauthResp
	env.doJSON("POST", "/v1/accounts/oauth", "", "",
		map[string]string{"accessToken": u2 + "|" + emailB, "password": "device-pw-999"},
		http.StatusOK, &again)
	if again.AccountID != adopt.AccountID || again.DeviceID != 3 {
		t.Fatalf("id match failed: %+v", again)
	}

	// Case-variant usernames collide.
	env.doJSON("POST", "/v1/accounts", "", "",
		map[string]string{"username": strings.ToUpper(bob), "password": "pw-12345678"},
		http.StatusConflict, nil)
	var avail struct {
		Available bool `json:"available"`
	}
	env.doJSON("GET", "/v1/usernames/"+strings.ToUpper(alice)+"/available", "", "", nil, http.StatusOK, &avail)
	if avail.Available {
		t.Fatal("case-variant of a taken username reported available")
	}
	env.doJSON("GET", "/v1/usernames/free"+sfx+"/available", "", "", nil, http.StatusOK, &avail)
	if !avail.Available {
		t.Fatal("unused username reported taken")
	}
}

// TestContactInviteSingleUse verifies a contact invite resolves exactly once:
// the first claim returns the inviter, a second claim is rejected.
func TestContactInviteSingleUse(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("alice-invite", "password-alice")
	bob := env.register("bob-invite", "password-bob")

	var created struct {
		Token     string `json:"token"`
		ExpiresAt int64  `json:"expiresAt"`
	}
	env.doJSON("POST", "/v1/contact-invites", alice.authUser(), alice.password, nil, http.StatusCreated, &created)
	if created.Token == "" || created.ExpiresAt <= time.Now().UnixMilli() {
		t.Fatalf("bad invite: %+v", created)
	}

	// First claim → resolves to alice.
	var claim struct {
		AccountID string `json:"accountId"`
		Username  string `json:"username"`
	}
	env.doJSON("POST", "/v1/contact-invites/claim", bob.authUser(), bob.password,
		map[string]string{"token": created.Token}, http.StatusOK, &claim)
	if claim.AccountID != alice.accountID || claim.Username != alice.username {
		t.Fatalf("first claim wrong: %+v", claim)
	}

	// Second claim of the same token → rejected (single-use).
	env.doJSON("POST", "/v1/contact-invites/claim", bob.authUser(), bob.password,
		map[string]string{"token": created.Token}, http.StatusNotFound, nil)

	// Unknown token → rejected.
	env.doJSON("POST", "/v1/contact-invites/claim", bob.authUser(), bob.password,
		map[string]string{"token": "deadbeef"}, http.StatusNotFound, nil)
}

// TestSealedSendDelivery verifies the unauthenticated sealed-send endpoint: it
// requires the recipient's access key, and the delivered envelope carries no
// sender fields (the relay doesn't learn who sent it).
func TestSealedSendDelivery(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register("alice-sealed", "password-alice")
	bob := env.register("bob-sealed", "password-bob")
	bob.uploadKeys(2)

	accessKey := bytes.Repeat([]byte{0x11}, 32)
	env.doJSON("PUT", "/v1/accounts/me/access-key", bob.authUser(), bob.password,
		map[string]string{"accessKey": base64.StdEncoding.EncodeToString(accessKey)},
		http.StatusNoContent, nil)

	// Alice fetches Bob's bundle → obtains his mailbox and access key.
	var keys struct {
		Devices []struct {
			MailboxID string `json:"mailboxId"`
		} `json:"devices"`
		AccessKey string `json:"accessKey"`
	}
	env.doJSON("GET", "/v1/keys/"+bob.accountID, alice.authUser(), alice.password, nil, http.StatusOK, &keys)
	if len(keys.Devices) == 0 || keys.Devices[0].MailboxID == "" {
		t.Fatalf("no mailbox returned")
	}
	if keys.AccessKey != base64.StdEncoding.EncodeToString(accessKey) {
		t.Fatalf("bundle access key mismatch: %q", keys.AccessKey)
	}
	mailbox := keys.Devices[0].MailboxID
	content := []byte("sealed-ciphertext-blob")

	// Wrong access key → rejected.
	env.doJSON("POST", "/v1/messages/sealed", "", "", map[string]any{
		"mailboxId": mailbox, "type": 2,
		"content":   base64.StdEncoding.EncodeToString(content),
		"accessKey": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x22}, 32)),
	}, http.StatusForbidden, nil)

	// Correct access key → accepted (queued while Bob is offline).
	env.doJSON("POST", "/v1/messages/sealed", "", "", map[string]any{
		"mailboxId": mailbox, "type": 2,
		"content":   base64.StdEncoding.EncodeToString(content),
		"accessKey": base64.StdEncoding.EncodeToString(accessKey),
	}, http.StatusOK, nil)

	// Bob drains the queue; the envelope must carry no sender.
	w := bob.connectWS()
	if len(w.queued) != 1 {
		t.Fatalf("expected 1 queued envelope, got %d", len(w.queued))
	}
	if w.queued[0].SenderAccount != "" || w.queued[0].SenderDevice != 0 {
		t.Fatalf("sealed envelope leaked sender: %q/%d", w.queued[0].SenderAccount, w.queued[0].SenderDevice)
	}
	if string(w.queued[0].Content) != string(content) {
		t.Fatalf("content mismatch")
	}
	// The sender's clock never reaches the wire: the relay stamps its own time.
	if w.queued[0].ClientTimestamp != w.queued[0].ServerTimestamp {
		t.Fatalf("sealed envelope carries a client clock: %d vs %d", w.queued[0].ClientTimestamp, w.queued[0].ServerTimestamp)
	}

	// Call rings use the same unauthenticated access-key capability.
	ring := func(mb string, key []byte, want int) {
		env.doJSON("POST", "/v1/calls/ring", "", "", map[string]any{
			"destinationMailbox": mb,
			"accessKey":          base64.StdEncoding.EncodeToString(key),
			"callId":             "3f1c2d9e-0000-4000-8000-000000000001",
		}, want, nil)
	}
	ring(mailbox, accessKey, http.StatusNoContent)
	ring(mailbox, bytes.Repeat([]byte{0x22}, 32), http.StatusForbidden)
	ring("0000000000000000000000000000dead", accessKey, http.StatusForbidden)
}

// TestAttachmentCapabilities: allocation is authenticated, but GET/PUT carry no
// credentials (the id is the capability) and an id can be written exactly once.
func TestAttachmentCapabilities(t *testing.T) {
	env := newTestEnv(t)
	alice := env.register(uniqueUsername("att"), "password-alice")

	var alloc struct {
		ID string `json:"id"`
	}
	env.doJSON("POST", "/v1/attachments", alice.authUser(), alice.password, nil, http.StatusCreated, &alloc)

	raw := func(method, path string, body []byte) int {
		req, err := http.NewRequest(method, env.srv.URL+path, bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if got := raw("PUT", "/v1/attachments/"+alloc.ID, []byte("ciphertext")); got != http.StatusNoContent {
		t.Fatalf("anonymous PUT of allocated id: %d", got)
	}
	if got := raw("PUT", "/v1/attachments/"+alloc.ID, []byte("overwrite")); got != http.StatusNotFound {
		t.Fatalf("second PUT: %d, want 404 (write-once)", got)
	}
	if got := raw("PUT", "/v1/attachments/0123456789abcdef0123456789abcdef", []byte("x")); got != http.StatusNotFound {
		t.Fatalf("PUT of unallocated id: %d, want 404", got)
	}
	if got := raw("GET", "/v1/attachments/"+alloc.ID, nil); got != http.StatusOK {
		t.Fatalf("anonymous GET: %d", got)
	}
}

func TestMailboxRotation(t *testing.T) {
	env := newTestEnv(t)
	bob := env.register("bob-rotate", "password-bob")
	bob.uploadKeys(2)

	accessKey := bytes.Repeat([]byte{0x11}, 32)
	env.doJSON("PUT", "/v1/accounts/me/access-key", bob.authUser(), bob.password,
		map[string]string{"accessKey": base64.StdEncoding.EncodeToString(accessKey)},
		http.StatusNoContent, nil)

	mailboxOf := func() string {
		var keys struct {
			Devices []struct {
				MailboxID string `json:"mailboxId"`
			} `json:"devices"`
		}
		env.doJSON("GET", "/v1/keys/"+bob.accountID, bob.authUser(), bob.password, nil, http.StatusOK, &keys)
		if len(keys.Devices) == 0 {
			t.Fatalf("no devices returned")
		}
		return keys.Devices[0].MailboxID
	}

	oldMailbox := mailboxOf()

	// Rotate → a new, different mailbox id.
	var rot struct {
		MailboxID string `json:"mailboxId"`
	}
	env.doJSON("POST", "/v1/devices/me/mailbox/rotate", bob.authUser(), bob.password, nil, http.StatusOK, &rot)
	if rot.MailboxID == "" || rot.MailboxID == oldMailbox {
		t.Fatalf("rotation did not produce a new mailbox: old=%q new=%q", oldMailbox, rot.MailboxID)
	}
	if got := mailboxOf(); got != rot.MailboxID {
		t.Fatalf("bundle still reports old mailbox: %q, want %q", got, rot.MailboxID)
	}

	send := func(mailbox string, want int) {
		env.doJSON("POST", "/v1/messages/sealed", "", "", map[string]any{
			"mailboxId": mailbox, "type": 2,
			"content":   base64.StdEncoding.EncodeToString([]byte("blob")),
			"accessKey": base64.StdEncoding.EncodeToString(accessKey),
		}, want, nil)
	}
	// The stale mailbox no longer routes; the new one does.
	send(oldMailbox, http.StatusForbidden)
	send(rot.MailboxID, http.StatusOK)
}

func TestBlindedDirectory(t *testing.T) {
	env := newTestEnv(t)
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}

	alice := env.register("alice-dir", "password-alice")
	bob := env.register("bob-dir", "password-bob")

	// Simulate the client's oblivious lookup of "bob-dir": blind H1(x), have the
	// server evaluate under k, unblind, derive the token — the server never sees x.
	id := []byte(oprf.Normalize(bob.username))
	h := sha512.New()
	h.Write([]byte("Relay-OPRF-v1-h2g"))
	h.Write(id)
	hx := ristretto255.NewElement().FromUniformBytes(h.Sum(nil))
	var rb [64]byte
	rand.Read(rb[:])
	r := ristretto255.NewScalar().FromUniformBytes(rb[:])
	blinded := ristretto255.NewElement().ScalarMult(r, hx).Encode(nil)

	var evalResp struct {
		Evaluated []string `json:"evaluated"`
	}
	env.doJSON("POST", "/v1/directory/oprf", alice.authUser(), alice.password,
		map[string]any{"blinded": []string{base64.StdEncoding.EncodeToString(blinded)}},
		http.StatusOK, &evalResp)
	if len(evalResp.Evaluated) != 1 {
		t.Fatalf("expected 1 evaluated element, got %d", len(evalResp.Evaluated))
	}
	eBytes, _ := base64.StdEncoding.DecodeString(evalResp.Evaluated[0])
	e := ristretto255.NewElement()
	if err := e.Decode(eBytes); err != nil {
		t.Fatalf("decode evaluated: %v", err)
	}
	n := ristretto255.NewElement().ScalarMult(ristretto255.NewScalar().Invert(r), e)
	th := sha256.New()
	th.Write([]byte("Relay-OPRF-v1-token"))
	th.Write(id)
	th.Write(n.Encode(nil))
	token := th.Sum(nil)

	// The token never leaves the client: only its 16-bit bucket is sent; the
	// client matches the tag and opens the box locally.
	fetch := func(tok []byte) (acct, user string, found bool) {
		var resp struct {
			Buckets []struct {
				Bucket  int `json:"bucket"`
				Entries []struct {
					Tag string `json:"tag"`
					Box string `json:"box"`
				} `json:"entries"`
			} `json:"buckets"`
		}
		env.doJSON("POST", "/v1/directory/buckets", alice.authUser(), alice.password,
			map[string]any{"buckets": []int{int(oprf.DirectoryBucket(tok))}}, http.StatusOK, &resp)
		if len(resp.Buckets) != 1 || resp.Buckets[0].Bucket != int(oprf.DirectoryBucket(tok)) {
			t.Fatalf("bucket response: %+v", resp)
		}
		want := base64.StdEncoding.EncodeToString(oprf.DirectoryTag(tok))
		for _, e := range resp.Buckets[0].Entries {
			if e.Tag != want {
				continue
			}
			box, _ := base64.StdEncoding.DecodeString(e.Box)
			a, u, err := oprf.OpenDirectoryEntry(tok, box)
			if err != nil {
				t.Fatalf("open box: %v", err)
			}
			return a, u, true
		}
		return "", "", false
	}
	if _, user, ok := fetch(token); !ok || user != bob.username {
		t.Fatalf("expected to resolve %s, got %q (found=%v)", bob.username, user, ok)
	}

	// An unknown token matches nothing — non-registered contacts stay private.
	junk := make([]byte, 32)
	rand.Read(junk)
	if _, _, ok := fetch(junk); ok {
		t.Fatal("unknown token resolved")
	}
}
