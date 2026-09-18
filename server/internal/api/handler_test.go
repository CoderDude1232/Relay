package api

import "testing"

// TestHandlerRegistersWithoutConflict guards against Go 1.22 ServeMux pattern
// conflicts (e.g. a `{id}` wildcard colliding with a sibling literal segment),
// which panic at registration time and crash-loop the server on startup.
//
// The integration test that also exercises Handler() is skipped unless a
// Postgres DSN is set, so this cheap, dependency-free check runs on every
// `go test` and catches route ambiguity before it reaches production.
func TestHandlerRegistersWithoutConflict(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("route registration panicked: %v", r)
		}
	}()
	// New only stores its dependencies; Handler() registers every route and is
	// where a conflicting pattern would panic. Nil deps are fine — no route is
	// invoked here.
	_ = New(nil, nil, nil, "", "").Handler()
}
