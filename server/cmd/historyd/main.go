// Command historyd stores chat-history backup segments for relayd when the
// relay host runs low on disk. It runs on another host (the TURN box) and
// holds only opaque ciphertext under keyed-hash names, so it can't tell whose
// backups it holds. Only relayd, which shares -secret-file, can call it.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/relayapp/relay-server/internal/history"
	"github.com/relayapp/relay-server/internal/privlog"
)

func main() {
	addr := flag.String("addr", ":9479", "listen address")
	dir := flag.String("dir", "/var/lib/historyd", "directory for blobs")
	secretFile := flag.String("secret-file", "", "file holding the secret shared with relayd (required, at least 32 bytes)")
	tlsCert := flag.String("tls-cert", "", "TLS certificate; plain HTTP only when both -tls-cert and -tls-key are empty")
	tlsKey := flag.String("tls-key", "", "TLS private key")
	maxBytes := flag.Int64("max-bytes", 10<<30, "cap on stored bytes (0 = only the 1 GiB free-disk floor)")
	flag.Parse()

	if *secretFile == "" {
		slog.Error("-secret-file is required")
		os.Exit(1)
	}
	if (*tlsCert == "") != (*tlsKey == "") {
		slog.Error("-tls-cert and -tls-key must be provided together")
		os.Exit(1)
	}
	secret, err := history.LoadSecret(*secretFile)
	if err != nil {
		slog.Error("read secret", "err", privlog.Error(err))
		os.Exit(1)
	}
	store, err := history.OpenDir(*dir)
	if err != nil {
		slog.Error("open blob directory", "err", privlog.Error(err))
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           history.NewBlobServer(store, secret, *maxBytes).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute,
		WriteTimeout:      2 * time.Minute,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          log.New(io.Discard, "", 0), // TLS handshake noise carries peer IPs
	}
	if *tlsCert != "" {
		certs := &certReloader{certFile: *tlsCert, keyFile: *tlsKey}
		if _, err := certs.get(nil); err != nil {
			slog.Error("load TLS certificate", "err", privlog.Error(err))
			os.Exit(1)
		}
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12, GetCertificate: certs.get}
	}
	go func() {
		slog.Info("historyd listening", "addr", *addr, "tls", *tlsCert != "", "usedBytes", store.Usage())
		var err error
		if *tlsCert != "" {
			err = srv.ListenAndServeTLS("", "")
		} else {
			err = srv.ListenAndServe()
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "err", privlog.Error(err))
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}

// certReloader re-reads the certificate when its file changes, so a renewed
// certificate (e.g. copied in by a certbot deploy hook) is used without a
// restart.
type certReloader struct {
	certFile, keyFile string

	mu      sync.Mutex
	cert    *tls.Certificate
	modTime time.Time
	checked time.Time
}

func (c *certReloader) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cert != nil && time.Since(c.checked) < time.Minute {
		return c.cert, nil
	}
	c.checked = time.Now()
	info, err := os.Stat(c.certFile)
	if err != nil {
		if c.cert != nil {
			return c.cert, nil
		}
		return nil, err
	}
	if c.cert != nil && info.ModTime().Equal(c.modTime) {
		return c.cert, nil
	}
	cert, err := tls.LoadX509KeyPair(c.certFile, c.keyFile)
	if err != nil {
		if c.cert != nil {
			return c.cert, nil // mid-copy; keep serving the old one
		}
		return nil, err
	}
	c.cert, c.modTime = &cert, info.ModTime()
	return c.cert, nil
}
