package api

import (
	"net/http/httptest"
	"testing"
)

func TestSourceAddrTrustsOnlyConfiguredProxies(t *testing.T) {
	t.Cleanup(func() { _ = SetTrustedProxies("") })

	req := func(remote, cf string) string {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = remote
		if cf != "" {
			r.Header.Set("CF-Connecting-IP", cf)
		}
		return clientIP(r)
	}

	// No proxies configured: the header is ignored.
	if got := req("198.51.100.7:4000", "203.0.113.9"); got != "198.51.100.7" {
		t.Fatalf("untrusted config: got %q", got)
	}

	if err := SetTrustedProxies("cloudflare"); err != nil {
		t.Fatal(err)
	}
	// From a Cloudflare edge: the forwarded client is used.
	if got := req("172.70.1.2:4000", "203.0.113.9"); got != "203.0.113.9" {
		t.Fatalf("via cloudflare: got %q", got)
	}
	// IPv6 client behind Cloudflare: bucketed to its /64.
	if got := req("[2606:4700::1]:4000", "2001:db8:1:2:3:4:5:6"); got != "2001:db8:1:2::/64" {
		t.Fatalf("v6 via cloudflare: got %q", got)
	}
	// Not from Cloudflare: a spoofed header must be ignored.
	if got := req("198.51.100.7:4000", "203.0.113.9"); got != "198.51.100.7" {
		t.Fatalf("spoofed header honoured: got %q", got)
	}
	// From Cloudflare but a garbage header: fall back to the peer.
	if got := req("172.70.1.2:4000", "not-an-ip"); got != "172.70.1.2" {
		t.Fatalf("bad header: got %q", got)
	}
	if err := SetTrustedProxies("10.0.0.0/8, bogus"); err == nil {
		t.Fatal("expected an error for a bad CIDR")
	}
}
