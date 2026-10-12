package store

import "strings"

// Names the app uses for itself and for system chats ("You", the Relay
// notices chat, Note to Self) and other names that would pass for staff or
// the system. They're compared after normalizing: lower case, look-alike
// digits read as letters, everything but letters dropped, so "Note_To_Self",
// "re1ay" and "y.o.u" are caught too. Names starting with "relay" are
// reserved as a whole.
var reservedNames = map[string]bool{
	"you": true, "me": true, "myself": true, "self": true, "note": true, "notes": true,
	"notetoself": true, "notestoself": true, "savedmessages": true,
	"system": true, "admin": true, "administrator": true, "support": true, "help": true,
	"helpdesk": true, "official": true, "team": true, "staff": true, "moderator": true,
	"mod": true, "security": true, "safety": true, "root": true, "null": true, "nil": true,
	"undefined": true, "unknown": true, "deleted": true, "deletedaccount": true,
	"anonymous": true, "everyone": true, "all": true, "here": true,
}

var leetReplacer = strings.NewReplacer("0", "o", "1", "i", "3", "e", "4", "a", "5", "s", "7", "t", "8", "b", "9", "g", "$", "s", "@", "a", "|", "l")

// normalizedName is name as compared against the reserved list.
func normalizedName(name string) string {
	lowered := leetReplacer.Replace(strings.ToLower(name))
	var b strings.Builder
	for _, r := range lowered {
		if r >= 'a' && r <= 'z' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ReservedUsername reports whether nobody may take name as a username.
func ReservedUsername(name string) bool {
	n := normalizedName(name)
	// "re1ay" reads as "reiay" once 1 becomes i; treat i and l alike here.
	ln := strings.ReplaceAll(n, "i", "l")
	return reservedNames[n] || reservedNames[ln] || strings.HasPrefix(ln, "relay") || strings.HasPrefix(n, "relay")
}
