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
	"github.com/relayapp/relay-server/internal/apns"
	"github.com/relayapp/relay-server/internal/blob"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/store"
)

// runBlobGC periodically reaps attachment blobs older than ttl.
func runBlobGC(blobs *blob.Store, ttl time.Duration) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for range ticker.C {
		if err := blobs.GC(ttl); err != nil {
			slog.Warn("blob gc failed", "err", err)
		}
	}
}

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	dbPath := flag.String("db", "relay.db", "path to SQLite database")
	tlsCert := flag.String("tls-cert", "", "path to TLS certificate (enables HTTPS/WSS)")
	tlsKey := flag.String("tls-key", "", "path to TLS private key")
	blobDir := flag.String("blobs", "attachments", "directory for encrypted attachment blobs")
	maxAttachment := flag.Int64("max-attachment", 25<<20, "max attachment blob size in bytes")
	blobTTL := flag.Duration("attachment-ttl", 30*24*time.Hour, "how long to keep attachment blobs")
	apnsKey := flag.String("apns-key", "", "path to APNs .p8 auth key (enables push)")
	apnsKeyID := flag.String("apns-key-id", "", "APNs key id")
	apnsTeamID := flag.String("apns-team-id", "", "Apple team id")
	apnsTopic := flag.String("apns-topic", "com.morgandaly.RelayTexting", "APNs topic (app bundle id)")
	apnsProduction := flag.Bool("apns-production", false, "use the APNs production host (default: sandbox)")
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

	blobs, err := blob.Open(*blobDir, *maxAttachment)
	if err != nil {
		slog.Error("failed to open blob store", "err", err)
		os.Exit(1)
	}
	go runBlobGC(blobs, *blobTTL)

	h := hub.New(st)
	if *apnsKey != "" {
		pusher, err := apns.New(*apnsKey, *apnsKeyID, *apnsTeamID, *apnsTopic, *apnsProduction)
		if err != nil {
			slog.Error("failed to load APNs key", "err", err)
			os.Exit(1)
		}
		h.SetPusher(pusher)
		slog.Info("apns push enabled", "topic", *apnsTopic, "production", *apnsProduction)
	}
	srv := &http.Server{
		Addr:              *addr,
		Handler:           api.New(st, h, blobs).Handler(),
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
