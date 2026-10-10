package api

import "testing"

// TestHandlerRegistersWithoutConflict guards against Go 1.22 ServeMux pattern
// conflicts (e.g. a {id} wildcard colliding with a sibling literal segment),
// which panic at registration time and crash-loop the server on startup. It
// needs no database, unlike the integration tests.
func TestHandlerRegistersWithoutConflict(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("route registration panicked: %v", r)
		}
	}()
	// New only stores its dependencies; Handler() registers every route and is
	// where a conflicting pattern would panic. Nil deps are fine since no route
	// is invoked.
	_ = New(nil, nil, nil, "", "").Handler()
}
