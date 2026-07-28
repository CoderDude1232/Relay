// relayd is the Relay messenger's server: a lean store-and-forward relay
// that never sees plaintext or private keys.
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/relayapp/relay-server/internal/api"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/store"
)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	dbPath := flag.String("db", "relay.db", "path to SQLite database")
	tlsCert := flag.String("tls-cert", "", "path to TLS certificate (enables HTTPS/WSS)")
	tlsKey := flag.String("tls-key", "", "path to TLS private key")
	flag.Parse()

	if (*tlsCert == "") != (*tlsKey == "") {
		slog.Error("-tls-cert and -tls-key must be provided together")
		os.Exit(1)
	}

	st, err := store.Open(*dbPath)
	if err != nil {
		slog.Error("failed to open store", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	h := hub.New(st)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           api.New(st, h).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	tlsEnabled := *tlsCert != ""
	go func() {
		slog.Info("relayd listening", "addr", *addr, "db", *dbPath, "tls", tlsEnabled)
		var err error
		if tlsEnabled {
			err = srv.ListenAndServeTLS(*tlsCert, *tlsKey)
		} else {
			err = srv.ListenAndServe()
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
	slog.Info("relayd stopped")
}
