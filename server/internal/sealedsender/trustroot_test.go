package sealedsender

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadOrCreateTrustRoot(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "trust.key")

	// Absent file: generated and persisted, then loaded back unchanged.
	kp, err := LoadOrCreateTrustRoot(path)
	if err != nil {
		t.Fatal(err)
	}
	again, err := LoadOrCreateTrustRoot(path)
	if err != nil || !bytes.Equal(again.Private, kp.Private) || !bytes.Equal(again.Public, kp.Public) {
		t.Fatalf("reload changed the key (err %v)", err)
	}

	// Any read error other than "does not exist" must fail, never mint a new
	// root: here the path is a directory.
	if _, err := LoadOrCreateTrustRoot(dir); err == nil {
		t.Fatal("unreadable trust-root path silently generated a new key")
	}

	// A write-only file can't be read but could be overwritten: the old loader
	// replaced the operator's key here. It must fail and leave the file alone.
	locked := filepath.Join(dir, "locked.key")
	if err := os.WriteFile(locked, []byte("original"), 0o200); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() != 0 { // root ignores file modes
		if _, err := LoadOrCreateTrustRoot(locked); err == nil {
			t.Fatal("permission error silently generated a new key")
		}
		os.Chmod(locked, 0o600)
		if data, _ := os.ReadFile(locked); string(data) != "original" {
			t.Fatal("unreadable trust-root file was overwritten")
		}
	}

	// A corrupt file is an error, not a reason to regenerate.
	corrupt := filepath.Join(dir, "corrupt.key")
	if err := os.WriteFile(corrupt, []byte("not hex"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateTrustRoot(corrupt); err == nil {
		t.Fatal("corrupt trust-root file accepted")
	}
	if data, _ := os.ReadFile(corrupt); string(data) != "not hex" {
		t.Fatal("corrupt trust-root file was overwritten")
	}
}
