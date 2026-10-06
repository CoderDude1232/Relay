package hub

import (
	"testing"

	"github.com/relayapp/relay-server/gen/relaypb"
)

type fakeSession struct{ closed string }

func (f *fakeSession) Send(*relaypb.ServerFrame) bool { return true }
func (f *fakeSession) Close(reason string)            { f.closed = reason }

// TestDisconnectAccount verifies that every session of the target account is
// detached and closed, other accounts are untouched, and presence is forgotten.
func TestDisconnectAccount(t *testing.T) {
	h := New(nil)
	a1, a2, other := &fakeSession{}, &fakeSession{}, &fakeSession{}
	h.sessions[key("acct", 1)] = a1
	h.sessions[key("acct", 2)] = a2
	h.sessions[key("acct-other", 1)] = other // shares a prefix but not "acct/"
	h.lastSeen["acct"] = 123

	if n := h.DisconnectAccount("acct", "account deleted"); n != 2 {
		t.Fatalf("closed %d sessions, want 2", n)
	}
	if a1.closed != "account deleted" || a2.closed != "account deleted" {
		t.Fatalf("sessions not closed: %q %q", a1.closed, a2.closed)
	}
	if other.closed != "" {
		t.Fatal("unrelated account's session was closed")
	}
	if h.IsOnline("acct") {
		t.Fatal("account still online after disconnect")
	}
	if !h.IsOnline("acct-other") {
		t.Fatal("unrelated account went offline")
	}
	if h.LastSeen("acct") != 0 {
		t.Fatal("presence not forgotten")
	}
	// The sessions' own deferred Unregister must now be a harmless no-op.
	h.Unregister("acct", 1, a1)
}
