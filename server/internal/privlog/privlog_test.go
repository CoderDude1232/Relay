package privlog

import (
	"errors"
	"strings"
	"testing"
)

func TestStringRedactsSensitiveValues(t *testing.T) {
	input := `Authorization: Bearer abcdef123456 token=secretvalue 123E4567-E89B-12D3-A456-426614174000`
	got := String(input)
	for _, leaked := range []string{"abcdef123456", "secretvalue", "123E4567-E89B-12D3-A456-426614174000"} {
		if strings.Contains(got, leaked) {
			t.Fatalf("redacted string leaked %q: %q", leaked, got)
		}
	}
}

func TestErrorRedactsSensitiveValues(t *testing.T) {
	got := Error(errors.New("postgres password=supersecret failed"))
	if strings.Contains(got, "supersecret") {
		t.Fatalf("redacted error leaked secret: %q", got)
	}
}
