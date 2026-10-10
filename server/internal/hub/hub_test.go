package hub

import (
	"testing"

	"github.com/relayapp/relay-server/gen/relaypb"
)

type fakeSession struct{ closed string }

func (f *fakeSession) Send(*relaypb.ServerFrame) bool { return true }
func (f *fakeSession) Close(reason string)            { f.closed = reason }

// TestDisconnectAccount verifies that every session of the target account is
// detached and closed and other accounts are untouched.
func TestDisconnectAccount(t *testing.T) {
	h := New(nil)
	a1, a2, other := &fakeSession{}, &fakeSession{}, &fakeSession{}
	h.sessions[key("acct", 1)] = a1
	h.sessions[key("acct", 2)] = a2
	h.sessions[key("acct-other", 1)] = other // shares a prefix but not "acct/"

	if n := h.DisconnectAccount("acct", "account deleted"); n != 2 {
		t.Fatalf("closed %d sessions, want 2", n)
	}
	if a1.closed != "account deleted" || a2.closed != "account deleted" {
		t.Fatalf("sessions not closed: %q %q", a1.closed, a2.closed)
	}
	if other.closed != "" {
		t.Fatal("unrelated account's session was closed")
	}
	if h.sessions[key("acct", 1)] != nil || h.sessions[key("acct", 2)] != nil {
		t.Fatal("account still has sessions after disconnect")
	}
	if h.sessions[key("acct-other", 1)] != other {
		t.Fatal("unrelated account's session was detached")
	}
	// The sessions' own deferred Unregister must be a harmless no-op.
	h.Unregister("acct", 1, a1)
}
