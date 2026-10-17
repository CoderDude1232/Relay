package api

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/history"
	"github.com/relayapp/relay-server/internal/oprf"
	"github.com/relayapp/relay-server/internal/store"
)

// enableHistory gives env local history storage in a temp dir and returns it.
func enableHistory(env *testEnv, remote *history.RemoteClient) (*history.Storage, string) {
	env.t.Helper()
	dir := filepath.Join(env.t.TempDir(), "history")
	local, err := history.OpenDir(dir)
	if err != nil {
		env.t.Fatal(err)
	}
	st := history.NewStorage([]byte("test-history-names"), local, 0, remote)
	env.api.SetHistory(st)
	return st, dir
}

// historyDo sends a signed request with a raw body. chunked hides the length.
func (c *client) historyDo(method, path string, body []byte, chunked bool) (int, []byte) {
	c.env.t.Helper()
	var rd io.Reader = bytes.NewReader(body)
	if chunked {
		rd = io.MultiReader(rd)
	}
	req, err := http.NewRequest(method, c.env.srv.URL+path, rd)
	if err != nil {
		c.env.t.Fatal(err)
	}
	if chunked {
		req.ContentLength = -1
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	c.sign(req, body)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.env.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func (c *client) putSegment(seq int64, body []byte, want int) {
	c.env.t.Helper()
	if got, msg := c.historyDo("PUT", fmt.Sprintf("/v1/history/%d", seq), body, false); got != want {
		c.env.t.Fatalf("PUT seq %d (%d bytes): got %d (%s), want %d", seq, len(body), got, msg, want)
	}
}

func (c *client) getSegment(seq int64) (int, []byte) {
	c.env.t.Helper()
	return c.historyDo("GET", fmt.Sprintf("/v1/history/%d", seq), nil, false)
}

type historyList struct {
	Segments []struct {
		Seq  int64 `json:"seq"`
		Size int   `json:"size"`
	} `json:"segments"`
	UsedBytes int64 `json:"usedBytes"`
	MaxBytes  int64 `json:"maxBytes"`
}

func (c *client) listHistory() historyList {
	c.env.t.Helper()
	var l historyList
	c.env.doJSON("GET", "/v1/history", c.authUser(), c.password, nil, http.StatusOK, &l)
	return l
}

// blobFiles counts blob files in dir.
func blobFiles(t *testing.T, dir string) int {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, e := range entries {
		if history.ValidKey(e.Name()) {
			n++
		}
	}
	return n
}

// waitFor polls cond for a few seconds (blob cleanup after a bulk delete runs
// in the background).
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestHistoryRoundTrip(t *testing.T) {
	env := newTestEnv(t)
	_, dir := enableHistory(env, nil)
	c := env.register("hist", "password-hist")
	other := env.register("hist-other", "password-other")

	if l := c.listHistory(); len(l.Segments) != 0 || l.UsedBytes != 0 || l.MaxBytes != store.MaxHistoryBytes {
		t.Fatalf("empty list: %+v", l)
	}
	if got, _ := c.getSegment(1000); got != http.StatusNotFound {
		t.Fatalf("GET before PUT: %d", got)
	}
	c.putSegment(1001, []byte("segment-one"), http.StatusNoContent)
	c.putSegment(1000, []byte("manifest"), http.StatusNoContent)
	c.putSegment(1001, []byte("segment-one-v2"), http.StatusNoContent) // replace
	if got, body := c.getSegment(1001); got != http.StatusOK || string(body) != "segment-one-v2" {
		t.Fatalf("GET 1001: %d %q", got, body)
	}
	l := c.listHistory()
	if len(l.Segments) != 2 || l.Segments[0].Seq != 1000 || l.Segments[1].Seq != 1001 ||
		l.Segments[1].Size != len("segment-one-v2") || l.UsedBytes != int64(len("manifest")+len("segment-one-v2")) {
		t.Fatalf("list: %+v", l)
	}
	if n := blobFiles(t, dir); n != 2 {
		t.Fatalf("%d blob files, want 2", n)
	}
	// File names don't carry the account id.
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), c.accountID) {
			t.Fatal("blob file name contains the account id")
		}
	}

	// Accounts see only their own segments.
	if got, _ := other.getSegment(1001); got != http.StatusNotFound {
		t.Fatalf("another account read a segment: %d", got)
	}
	if l := other.listHistory(); len(l.Segments) != 0 {
		t.Fatalf("another account's list: %+v", l)
	}

	// Bad seqs and bodies.
	for _, seq := range []string{"0", "-1", "01", "+5", "abc", "9007199254740993"} {
		if got, _ := c.historyDo("PUT", "/v1/history/"+seq, []byte("x"), false); got != http.StatusBadRequest {
			t.Errorf("PUT seq %q: %d, want 400", seq, got)
		}
	}
	c.putSegment(1<<53, []byte("max seq"), http.StatusNoContent)
	c.putSegment(1002, nil, http.StatusBadRequest)

	// Single delete, idempotent.
	for range 2 {
		if got, _ := c.historyDo("DELETE", "/v1/history/1001", nil, false); got != http.StatusNoContent {
			t.Fatalf("DELETE 1001: %d", got)
		}
	}
	if got, _ := c.getSegment(1001); got != http.StatusNotFound {
		t.Fatalf("GET after DELETE: %d", got)
	}
	// Delete all.
	if got, _ := c.historyDo("DELETE", "/v1/history", nil, false); got != http.StatusNoContent {
		t.Fatalf("DELETE all: %d", got)
	}
	if l := c.listHistory(); len(l.Segments) != 0 || l.UsedBytes != 0 {
		t.Fatalf("list after DELETE all: %+v", l)
	}
	waitFor(t, "blobs removed", func() bool { return blobFiles(t, dir) == 0 })
}

func TestHistoryLimits(t *testing.T) {
	env := newTestEnv(t)
	enableHistory(env, nil)
	c := env.register("hist-quota", "password-quota")

	// Over 2 MiB: 413, whether or not the length is declared.
	over := make([]byte, history.MaxSegmentBytes+1)
	c.putSegment(1, over, http.StatusRequestEntityTooLarge)
	if got, _ := c.historyDo("PUT", "/v1/history/1", over, true); got != http.StatusRequestEntityTooLarge {
		t.Fatalf("chunked oversized PUT: %d", got)
	}

	// Fill the quota exactly with 2 MiB segments.
	full := bytes.Repeat([]byte{0xA5}, history.MaxSegmentBytes)
	n := int64(store.MaxHistoryBytes / history.MaxSegmentBytes)
	for seq := int64(1); seq <= n; seq++ {
		c.putSegment(seq, full, http.StatusNoContent)
	}
	if l := c.listHistory(); l.UsedBytes != store.MaxHistoryBytes {
		t.Fatalf("used %d, want %d", l.UsedBytes, store.MaxHistoryBytes)
	}
	c.putSegment(n+1, []byte("x"), http.StatusInsufficientStorage)
	// Replacing a segment counts only the new size.
	c.putSegment(1, full, http.StatusNoContent)
	c.putSegment(1, []byte("smaller"), http.StatusNoContent)
	c.putSegment(n+1, []byte("fits now"), http.StatusNoContent)
	if got, body := c.getSegment(1); got != http.StatusOK || string(body) != "smaller" {
		t.Fatalf("GET replaced segment: %d %q", got, body[:min(len(body), 16)])
	}

	// Without storage: 507.
	env.api.SetHistory(nil)
	c.putSegment(n+2, []byte("x"), http.StatusInsufficientStorage)
	enableHistory(env, nil)

	// Demo accounts can't upload.
	demo := env.register("hist-demo", "password-demo")
	if err := env.api.store.SetDemoAccount(demo.accountID, true); err != nil {
		t.Fatal(err)
	}
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()
	demo.putSegment(1, []byte("x"), http.StatusForbidden)
}

func TestHistoryRateLimit(t *testing.T) {
	env := newTestEnv(t)
	enableHistory(env, nil)
	c := env.register("hist-rate", "password-rate")
	for i := range 600 {
		if got, _ := c.getSegment(1); got != http.StatusNotFound {
			t.Fatalf("GET %d: %d", i, got)
		}
	}
	if got, _ := c.getSegment(1); got != http.StatusTooManyRequests {
		t.Fatalf("GET 601: %d, want 429", got)
	}
	// Each verb has its own budget.
	c.putSegment(1, []byte("x"), http.StatusNoContent)
}

func TestHistoryRemovedWithAccount(t *testing.T) {
	env := newTestEnv(t)
	_, dir := enableHistory(env, nil)
	c := env.register("hist-del", "password-del")
	c.putSegment(1000, []byte("manifest"), http.StatusNoContent)
	c.putSegment(1001, []byte("segment"), http.StatusNoContent)

	env.doJSON("DELETE", "/v1/accounts/me", c.authUser(), c.password, nil, http.StatusNoContent, nil)
	if segs, _, err := env.api.store.HistorySegments(c.accountID); err != nil || len(segs) != 0 {
		t.Fatalf("rows after account deletion: %+v %v", segs, err)
	}
	waitFor(t, "blobs removed", func() bool { return blobFiles(t, dir) == 0 })

	// A demo reset clears history too. Demo accounts can't upload, so the
	// segment goes in before the account is marked demo.
	demo := env.register("hist-demo-reset", "password-demo")
	demo.putSegment(1000, []byte("before demo"), http.StatusNoContent)
	if err := env.api.store.SetDemoAccount(demo.accountID, true); err != nil {
		t.Fatal(err)
	}
	demoFlags.mu.Lock()
	demoFlags.entries = map[string]demoCacheEntry{}
	demoFlags.mu.Unlock()
	env.doJSON("DELETE", "/v1/accounts/me", demo.authUser(), demo.password, nil, http.StatusNoContent, nil)
	if segs, _, err := env.api.store.HistorySegments(demo.accountID); err != nil || len(segs) != 0 {
		t.Fatalf("rows after demo reset: %+v %v", segs, err)
	}
	waitFor(t, "demo blobs removed", func() bool { return blobFiles(t, dir) == 0 })
}

// A sign-in that replaces every device keeps the history: restoring onto the
// new device is what it's for.
func TestHistoryKeptAcrossDeviceReplacement(t *testing.T) {
	env := newTestEnv(t)
	enableHistory(env, nil)
	stubSupabase(env)
	key, err := oprf.Generate()
	if err != nil {
		t.Fatal(err)
	}
	if err := env.api.SetOPRF(key); err != nil {
		t.Fatal(err)
	}
	sfx := uniqueUsername("")
	token := "hu" + sfx + "|h" + sfx + "@x.com|0"
	var reg struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
		MailboxID string `json:"mailboxId"`
	}
	env.doJSON("POST", "/v1/accounts", "", "", map[string]string{
		"username": "hist" + strings.ReplaceAll(sfx, "-", ""), "password": "device-pw-1", "supabaseAccessToken": token,
	}, http.StatusCreated, &reg)
	old := &client{env: env, accountID: reg.AccountID, deviceID: reg.DeviceID, mailboxID: reg.MailboxID, password: "device-pw-1"}
	env.clients[old.authUser()] = old
	old.uploadDeviceAuthKey()
	old.putSegment(2000, []byte("manifest"), http.StatusNoContent)
	old.putSegment(2001, []byte("history"), http.StatusNoContent)

	var signIn struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
		MailboxID string `json:"mailboxId"`
	}
	env.doJSON("POST", "/v1/accounts/oauth", "", "",
		map[string]string{"accessToken": token, "password": "device-pw-2"}, http.StatusOK, &signIn)
	if signIn.AccountID != reg.AccountID || signIn.DeviceID == reg.DeviceID {
		t.Fatalf("sign-in: %+v (registered %+v)", signIn, reg)
	}
	if devs, err := env.api.store.Devices(reg.AccountID); err != nil || len(devs) != 1 {
		t.Fatalf("devices after sign-in: %+v %v", devs, err)
	}
	fresh := &client{env: env, accountID: signIn.AccountID, deviceID: signIn.DeviceID, mailboxID: signIn.MailboxID, password: "device-pw-2"}
	env.clients[fresh.authUser()] = fresh
	fresh.uploadDeviceAuthKey()
	if l := fresh.listHistory(); len(l.Segments) != 2 {
		t.Fatalf("history after device replacement: %+v", l)
	}
	if got, body := fresh.getSegment(2001); got != http.StatusOK || string(body) != "history" {
		t.Fatalf("GET after device replacement: %d %q", got, body)
	}
}

// With the local disk "full", segments go to historyd and read back from it;
// once there's room again, a replaced segment moves back and the remote copy
// goes.
func TestHistoryFailoverToRemote(t *testing.T) {
	env := newTestEnv(t)
	remoteDir, err := history.OpenDir(filepath.Join(t.TempDir(), "remote"))
	if err != nil {
		t.Fatal(err)
	}
	secret := []byte("history-test-secret-0123456789abcdef")
	historyd := httptest.NewServer(history.NewBlobServer(remoteDir, secret, 0).Handler())
	t.Cleanup(historyd.Close)
	remote := history.NewRemote(historyd.URL, secret)
	if !remote.Probe(context.Background()) {
		t.Fatal("historyd probe failed")
	}
	st, localDir := enableHistory(env, remote)
	st.SetMinFree(1 << 62)

	c := env.register("hist-failover", "password-failover")
	c.putSegment(3000, []byte("remote manifest"), http.StatusNoContent)
	c.putSegment(3001, []byte("remote segment"), http.StatusNoContent)
	if seg, err := env.api.store.HistorySegment(c.accountID, 3001); err != nil || seg.Location != string(history.Remote) {
		t.Fatalf("row: %+v %v", seg, err)
	}
	if n := blobFiles(t, localDir); n != 0 {
		t.Fatalf("%d local blobs with the local disk full", n)
	}
	if list, _ := remoteDir.List(); len(list) != 2 {
		t.Fatalf("%d remote blobs, want 2", len(list))
	}
	if got, body := c.getSegment(3001); got != http.StatusOK || string(body) != "remote segment" {
		t.Fatalf("GET from remote: %d %q", got, body)
	}

	// Room again: the replacement lands locally and the remote copy is removed.
	st.SetMinFree(0)
	c.putSegment(3001, []byte("local segment"), http.StatusNoContent)
	if seg, _ := env.api.store.HistorySegment(c.accountID, 3001); seg.Location != string(history.Local) {
		t.Fatalf("replacement location: %q", seg.Location)
	}
	if list, _ := remoteDir.List(); len(list) != 1 {
		t.Fatalf("%d remote blobs after moving one back, want 1", len(list))
	}
	if got, body := c.getSegment(3001); got != http.StatusOK || string(body) != "local segment" {
		t.Fatalf("GET after moving back: %d %q", got, body)
	}
	if got, _ := c.historyDo("DELETE", "/v1/history/3000", nil, false); got != http.StatusNoContent {
		t.Fatalf("DELETE remote segment: %d", got)
	}
	if list, _ := remoteDir.List(); len(list) != 0 {
		t.Fatalf("%d remote blobs after delete", len(list))
	}

	// Local full and remote down: 507.
	st.SetMinFree(1 << 62)
	historyd.Close()
	remote.Failed()
	c.putSegment(3002, []byte("nowhere"), http.StatusInsufficientStorage)
}
