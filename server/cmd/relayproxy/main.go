// Command relayproxy lets Relay work where the relay itself is blocked. Anyone
// can run it on a VPS with a domain name; Relay users enter that domain in
// Settings → Privacy → Proxy.
//
// The app opens a TLS connection to this server (an ordinary-looking HTTPS
// connection to the proxy's own domain) and sends an HTTP CONNECT for the
// relay inside it. The proxy splices that stream to the relay, which the app
// then speaks TLS to end to end, so the proxy only ever sees encrypted bytes.
// Only the hosts in -allow can be reached, so it can't be used as an open proxy.
// Anything that isn't a CONNECT gets a plain 404, like a bare web server.
//
// TLS comes from Let's Encrypt via -domain (TLS-ALPN-01 on port 443, so
// nothing else needs to be open), or from -cert/-key. No client addresses are
// logged.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/acme/autocert"
)

// The relay's API and its sign-in provider.
const defaultAllow = "api.relaymsg.app:443,kmhxqtouqlfefzaedoqx.supabase.co:443"

func main() {
	addr := flag.String("addr", ":443", "listen address")
	domain := flag.String("domain", "", "this proxy's domain, for an automatic Let's Encrypt certificate")
	cacheDir := flag.String("cache-dir", "/var/lib/relayproxy/certs", "certificate cache for -domain")
	certFile := flag.String("cert", "", "TLS certificate (instead of -domain)")
	keyFile := flag.String("key", "", "TLS key (instead of -domain)")
	allow := flag.String("allow", defaultAllow, "comma-separated host:port targets clients may reach")
	maxConns := flag.Int("max-conns", 4000, "maximum concurrent tunnels")
	flag.Parse()

	p := newProxy(*allow, *maxConns)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           p,
		ReadHeaderTimeout: 10 * time.Second,
		ErrorLog:          log.New(io.Discard, "", 0), // TLS handshake noise includes client addresses
	}

	switch {
	case *domain != "":
		m := &autocert.Manager{
			Prompt:     autocert.AcceptTOS,
			HostPolicy: autocert.HostWhitelist(*domain),
			Cache:      autocert.DirCache(*cacheDir),
		}
		srv.TLSConfig = m.TLSConfig()
		log.Printf("relayproxy: serving %s on %s", *domain, *addr)
		log.Fatal(srv.ListenAndServeTLS("", ""))
	case *certFile != "" && *keyFile != "":
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12, NextProtos: []string{"h2", "http/1.1"}}
		log.Printf("relayproxy: serving on %s", *addr)
		log.Fatal(srv.ListenAndServeTLS(*certFile, *keyFile))
	default:
		log.Fatal("relayproxy: set -domain, or -cert and -key")
	}
}

type proxy struct {
	allowed map[string]bool
	slots   chan struct{}
	dial    func(ctx context.Context, network, addr string) (net.Conn, error)
}

func newProxy(allow string, maxConns int) *proxy {
	p := &proxy{
		allowed: map[string]bool{},
		slots:   make(chan struct{}, maxConns),
		dial:    (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
	}
	for _, target := range strings.Split(allow, ",") {
		if t := strings.ToLower(strings.TrimSpace(target)); t != "" {
			p.allowed[t] = true
		}
	}
	return p
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect {
		http.NotFound(w, r)
		return
	}
	target := strings.ToLower(r.Host)
	if !p.allowed[target] {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	default:
		http.Error(w, "busy", http.StatusServiceUnavailable)
		return
	}
	upstream, err := p.dial(r.Context(), "tcp", target)
	if err != nil {
		http.Error(w, "unreachable", http.StatusBadGateway)
		return
	}
	defer upstream.Close()

	if r.ProtoMajor == 1 {
		p.tunnelHTTP1(w, upstream)
	} else {
		p.tunnelHTTP2(w, r, upstream)
	}
}

// tunnelHTTP1 takes over the client connection and splices it to upstream.
func (p *proxy) tunnelHTTP1(w http.ResponseWriter, upstream net.Conn) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "unsupported", http.StatusInternalServerError)
		return
	}
	client, buffered, err := hj.Hijack()
	if err != nil {
		return
	}
	defer client.Close()
	if _, err := client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		return
	}
	// Bytes the client sent right after the CONNECT may already be buffered.
	if n := buffered.Reader.Buffered(); n > 0 {
		pending := make([]byte, n)
		if _, err := io.ReadFull(buffered.Reader, pending); err != nil {
			return
		}
		if _, err := upstream.Write(pending); err != nil {
			return
		}
	}
	splice(client, upstream)
}

// tunnelHTTP2 streams the CONNECT request body to upstream and upstream to
// the response, which HTTP/2 allows in both directions at once.
func (p *proxy) tunnelHTTP2(w http.ResponseWriter, r *http.Request, upstream net.Conn) {
	rc := http.NewResponseController(w)
	w.WriteHeader(http.StatusOK)
	if err := rc.Flush(); err != nil {
		return
	}
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(upstream, r.Body)
		if tcp, ok := upstream.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		close(done)
	}()
	buf := make([]byte, 32*1024)
	for {
		n, err := upstream.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			if rc.Flush() != nil {
				break
			}
		}
		if err != nil {
			break
		}
	}
	upstream.Close()
	<-done
}

// splice copies both ways until either side closes.
func splice(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	copyHalf := func(dst, src net.Conn) {
		defer wg.Done()
		_, err := io.Copy(dst, src)
		if err != nil && !errors.Is(err, net.ErrClosed) {
			_ = dst.Close()
			return
		}
		if tcp, ok := dst.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	go copyHalf(a, b)
	go copyHalf(b, a)
	wg.Wait()
}
