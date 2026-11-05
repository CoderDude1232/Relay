package tunnel

import (
	"bytes"
	"path/filepath"
	"testing"
)

func testKey(t *testing.T) (*Key, *Client) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tunnel.key")
	k, err := LoadOrCreateKey(path)
	if err != nil {
		t.Fatal(err)
	}
	again, err := LoadOrCreateKey(path)
	if err != nil || !bytes.Equal(again.PublicKey(), k.PublicKey()) {
		t.Fatal("reloaded key differs")
	}
	c, err := NewClient(k.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	return k, c
}

func TestRoundTrip(t *testing.T) {
	k, c := testKey(t)
	req := &Request{Method: "PUT", Scheme: "https", Authority: "relay", Path: "/v1/history/1001?x=1",
		Header: [][2]string{{"authorization", "Relay-Sig a.1:sig"}, {"content-type", "application/octet-stream"}},
		Body:   bytes.Repeat([]byte{7}, 70_000)}
	msg, pending, err := c.Seal(req)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := k.Open(msg)
	if err != nil {
		t.Fatal(err)
	}
	got := opened.Request
	if got.Method != req.Method || got.Path != req.Path || !bytes.Equal(got.Body, req.Body) ||
		len(got.Header) != 2 || got.Header[0] != req.Header[0] {
		t.Fatalf("request didn't survive: %+v", got.Header)
	}
	sealed, err := opened.Seal(&Response{Status: 429, Header: [][2]string{{"retry-after", "5"}}, Body: []byte(`{"error":"slow down"}`)})
	if err != nil {
		t.Fatal(err)
	}
	resp, err := pending.Open(sealed)
	if err != nil || resp.Status != 429 || string(resp.Body) != `{"error":"slow down"}` || resp.Header[0][1] != "5" {
		t.Fatalf("response: %+v %v", resp, err)
	}

	// Tampering anywhere fails.
	for _, i := range []int{0, 3, hdrLen + 10, len(msg) - 1} {
		bad := bytes.Clone(msg)
		bad[i] ^= 1
		if _, err := k.Open(bad); err == nil {
			t.Errorf("tampered byte %d opened", i)
		}
	}
	bad := bytes.Clone(sealed)
	bad[len(bad)-1] ^= 1
	if _, err := pending.Open(bad); err == nil {
		t.Error("tampered response opened")
	}
}

func TestPadding(t *testing.T) {
	for n, want := range map[int]int{0: 256, 256: 256, 257: 512, 5000: 8192, 65536: 65536, 65537: 131072, 200_000: 262144} {
		if got := PaddedLen(n); got != want {
			t.Errorf("PaddedLen(%d) = %d, want %d", n, got, want)
		}
	}
	// Two requests whose bodies differ in size inside a bucket look the same.
	_, c := testKey(t)
	a, _, _ := c.Seal(&Request{Method: "GET", Path: "/v1/a"})
	b, _, _ := c.Seal(&Request{Method: "POST", Path: "/v1/messages/sealed", Body: make([]byte, 150)})
	if len(a) != len(b) {
		t.Fatalf("sizes leak: %d vs %d", len(a), len(b))
	}
}

func TestStream(t *testing.T) {
	k, c := testKey(t)
	msg, pending, _ := c.Seal(&Request{Method: "GET", Path: "/v1/ws"})
	opened, err := k.Open(msg)
	if err != nil {
		t.Fatal(err)
	}
	server, _ := opened.Stream()
	client, _ := pending.Stream()
	for _, frame := range [][]byte{[]byte("one"), {}, bytes.Repeat([]byte{1}, 100_000)} {
		got, err := server.Open(client.Seal(frame))
		if err != nil || !bytes.Equal(got, frame) {
			t.Fatalf("c2s: %v", err)
		}
		got, err = client.Open(server.Seal(frame))
		if err != nil || !bytes.Equal(got, frame) {
			t.Fatalf("s2c: %v", err)
		}
	}
	// Replayed or reordered frames don't open.
	first := client.Seal([]byte("a"))
	second := client.Seal([]byte("b"))
	if _, err := server.Open(second); err == nil {
		t.Fatal("out-of-order frame opened")
	}
	if _, err := server.Open(first); err != nil {
		t.Fatal(err)
	}
	if _, err := server.Open(first); err == nil {
		t.Fatal("replayed frame opened")
	}
}
