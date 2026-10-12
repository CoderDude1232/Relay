package store

import "testing"

func TestReservedUsername(t *testing.T) {
	for _, name := range []string{
		"relay", "Relay", "RELAY", "re1ay", "relay_support", "relay.team", "Relay-Official",
		"you", "You", "y.o.u", "y0u", "notetoself", "Note_To_Self", "note-to-self", "n0tet0self",
		"admin", "Support", "system", "deleted_account", "me",
	} {
		if !ReservedUsername(name) {
			t.Errorf("%q should be reserved", name)
		}
	}
	for _, name := range []string{"ethan", "morgan", "youngblood", "notebook_fan", "alice_relayfan", "yours", "meg", "selfie"} {
		if ReservedUsername(name) {
			t.Errorf("%q should be allowed", name)
		}
	}
}
