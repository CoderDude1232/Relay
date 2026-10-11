package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// echoServer accepts one connection and echoes what it reads.
func echoServer(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
		}
	}()
	return ln
}

func TestConnectTunnelsOnlyToAllowedTargets(t *testing.T) {
	echo := echoServer(t)
	defer echo.Close()

	p := newProxy("api.relaymsg.app:443", 10)
	// Every allowed name resolves to the local echo server.
	p.dial = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return net.Dial("tcp", echo.Addr().String())
	}
	srv := httptest.NewServer(p)
	defer srv.Close()
	host := strings.TrimPrefix(srv.URL, "http://")

	connect := func(target string) (net.Conn, *bufio.Reader, int) {
		c, err := net.Dial("tcp", host)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
		br := bufio.NewReader(c)
		resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
		if err != nil {
			t.Fatal(err)
		}
		return c, br, resp.StatusCode
	}

	c, br, status := connect("api.relaymsg.app:443")
	defer c.Close()
	if status != http.StatusOK {
		t.Fatalf("allowed target: status %d", status)
	}
	fmt.Fprint(c, "hello")
	got := make([]byte, 5)
	if _, err := io.ReadFull(br, got); err != nil || string(got) != "hello" {
		t.Fatalf("tunnel echo = %q, %v", got, err)
	}

	c2, _, status := connect("example.com:443")
	defer c2.Close()
	if status != http.StatusForbidden {
		t.Fatalf("disallowed target: status %d, want 403", status)
	}

	// Ordinary requests look like an empty web server.
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("GET /: status %d, want 404", resp.StatusCode)
	}
}

func TestBusyWhenFull(t *testing.T) {
	p := newProxy("api.relaymsg.app:443", 1)
	p.slots <- struct{}{}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodConnect, "http://api.relaymsg.app:443", nil)
	req.Host = "api.relaymsg.app:443"
	p.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d, want 503", rec.Code)
	}
}

func TestPerIPCap(t *testing.T) {
	p := newProxy("api.relaymsg.app:443", 10)
	p.perIP = 2
	if !p.acquire("192.0.2.1:1000") || !p.acquire("192.0.2.1:1001") {
		t.Fatal("first two tunnels refused")
	}
	if p.acquire("192.0.2.1:1002") {
		t.Fatal("third tunnel from the same address allowed")
	}
	if !p.acquire("192.0.2.2:1000") {
		t.Fatal("another address refused")
	}
	p.release("192.0.2.1:1000")
	if !p.acquire("192.0.2.1:1003") {
		t.Fatal("slot not returned on release")
	}
	if len(p.slots) != 3 {
		t.Fatalf("global slots in use = %d, want 3", len(p.slots))
	}
}
