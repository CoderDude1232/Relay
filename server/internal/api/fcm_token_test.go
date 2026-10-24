package api

import (
	"strings"
	"testing"
)

func TestValidFCMToken(t *testing.T) {
	good := []string{
		"dQw4w9WgXcQ:APA91bH" + strings.Repeat("a", 140),
		strings.Repeat("A", 32),
		"abc_DEF-123:" + strings.Repeat("x", 100),
	}
	for _, tok := range good {
		if !validFCMToken(tok) {
			t.Errorf("rejected valid token %q", tok)
		}
	}
	bad := []string{
		"",
		"short",
		strings.Repeat("a", 4097),
		strings.Repeat("a", 40) + "/../",
		strings.Repeat("a", 40) + " ",
		strings.Repeat("a", 40) + "\n",
		strings.Repeat("a", 40) + `"}`,
	}
	for _, tok := range bad {
		if validFCMToken(tok) {
			t.Errorf("accepted invalid token %q", tok)
		}
	}
}
