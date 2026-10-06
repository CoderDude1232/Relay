// relayd is the Relay messenger's server: a lean store-and-forward relay
// that never sees plaintext or private keys.
package main

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/quic-go/quic-go/http3"
	"github.com/relayapp/relay-server/internal/api"
	"github.com/relayapp/relay-server/internal/apns"
	"github.com/relayapp/relay-server/internal/blob"
	"github.com/relayapp/relay-server/internal/fcm"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/oprf"
	"github.com/relayapp/relay-server/internal/privlog"
	"github.com/relayapp/relay-server/internal/sealedsender"
	"github.com/relayapp/relay-server/internal/store"
)

// runBlobGC periodically reaps attachment blobs older than ttl.
func runBlobGC(blobs *blob.Store, ttl time.Duration) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for range ticker.C {
		if err := blobs.GC(ttl); err != nil {
			slog.Warn("blob gc failed", "err", privlog.Error(err))
		}
	}
}

// runRateLimiterGC periodically removes stale keys from the in-memory rate
// limiters so they don't grow unboundedly in long-running deployments.
func runRateLimiterGC(h *api.Server) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for range ticker.C {
		h.PruneStaleLimiterKeys()
	}
}

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	dsn := flag.String("dsn", "postgres://relay:relay@localhost/relay?sslmode=disable", "PostgreSQL DSN")
	tlsCert := flag.String("tls-cert", "", "path to TLS certificate (enables HTTPS/WSS)")
	tlsKey := flag.String("tls-key", "", "path to TLS private key")
	blobDir := flag.String("blobs", "attachments", "directory for encrypted attachment blobs")
	maxAttachment := flag.Int64("max-attachment", 25<<20, "max attachment blob size in bytes")
	blobTTL := flag.Duration("attachment-ttl", 30*24*time.Hour, "how long to keep attachment blobs")
	apnsKey := flag.String("apns-key", "", "path to APNs .p8 auth key (enables push)")
	apnsKeyID := flag.String("apns-key-id", "", "APNs key id")
	apnsTeamID := flag.String("apns-team-id", "", "Apple team id")
	apnsTopic := flag.String("apns-topic", "app.relaymsg", "APNs topic (app bundle id)")
	apnsProduction := flag.Bool("apns-production", false, "use the APNs production host (default: sandbox)")
	fcmServiceAccount := flag.String("fcm-service-account", "", "path to a Firebase service-account JSON key (enables FCM push for Android devices)")
	turnURLs := flag.String("turn-urls", "", "comma-separated TURN server URLs (enables dynamic TURN credentials)")
	turnSecret := flag.String("turn-secret", "", "shared HMAC-SHA1 secret for coturn REST API credential generation")
	supabaseURL := flag.String("supabase-url", "", "Supabase project URL (enables social-login account recovery via POST /v1/accounts/oauth)")
	supabaseAnonKey := flag.String("supabase-anon-key", "", "Supabase anon API key (sent as the apikey header when verifying user tokens)")
	supabaseServiceKeyFile := flag.String("supabase-service-key-file", "", "path to a file holding the Supabase service-role key (enables deleting the Supabase auth user on account deletion)")
	sealedKey := flag.String("sealed-sender-trust-key", "", "path to the sealed-sender trust-root private key (hex, 32 bytes); generated if absent, enables GET /v1/certificate/delivery")
	oprfKey := flag.String("oprf-key", "", "path to the blinded-discovery OPRF secret key (hex ristretto255 scalar); generated if absent, enables /v1/directory/*")
	flag.Parse()

	if (*tlsCert == "") != (*tlsKey == "") {
		slog.Error("-tls-cert and -tls-key must be provided together")
		os.Exit(1)
	}

	st, err := store.Open(*dsn)
	if err != nil {
		slog.Error("failed to open store", "err", privlog.Error(err))
		os.Exit(1)
	}
	defer st.Close()

	blobs, err := blob.Open(*blobDir, *maxAttachment)
	if err != nil {
		slog.Error("failed to open blob store", "err", privlog.Error(err))
		os.Exit(1)
	}
	go runBlobGC(blobs, *blobTTL)

	h := hub.New(st)
	if *apnsKey != "" {
		pusher, err := apns.New(*apnsKey, *apnsKeyID, *apnsTeamID, *apnsTopic, *apnsProduction)
		if err != nil {
			slog.Error("failed to load APNs key", "err", privlog.Error(err))
			os.Exit(1)
		}
		h.SetPusher(pusher)
		h.SetVoIPPusher(pusher) // same key/cert sends VoIP pushes on the .voip sub-topic
		slog.Info("apns push enabled", "topic", *apnsTopic, "production", *apnsProduction)
	}
	if *fcmServiceAccount != "" {
		fcmPusher, err := fcm.New(*fcmServiceAccount)
		if err != nil {
			slog.Error("failed to load FCM service account", "err", privlog.Error(err))
			os.Exit(1)
		}
		h.SetFCMPusher(fcmPusher)
		slog.Info("fcm push enabled")
	}

	apiServer := api.New(st, h, blobs, *turnURLs, *turnSecret)
	if *supabaseURL != "" {
		apiServer.SetSupabaseAuth(*supabaseURL, *supabaseAnonKey)
		slog.Info("supabase social login enabled", "url", *supabaseURL)
		if *supabaseServiceKeyFile != "" {
			key, err := os.ReadFile(*supabaseServiceKeyFile)
			if err != nil {
				slog.Error("read supabase service key", "err", err)
				os.Exit(1)
			}
			apiServer.SetSupabaseServiceKey(string(key))
			slog.Info("supabase auth-user deletion enabled")
		}
	}
	if *sealedKey != "" {
		trustRoot, err := sealedsender.LoadOrCreateTrustRoot(*sealedKey)
		if err != nil {
			slog.Error("failed to load sealed-sender trust root", "err", privlog.Error(err))
			os.Exit(1)
		}
		if err := apiServer.SetSealedSender(trustRoot); err != nil {
			slog.Error("failed to init sealed sender", "err", privlog.Error(err))
			os.Exit(1)
		}
		// The client must embed this trust-root public key to validate certs.
		slog.Info("sealed sender enabled",
			"trustRootPublicBase64", base64.StdEncoding.EncodeToString(trustRoot.Public))
	}
	if *oprfKey != "" {
		key, err := oprf.LoadOrCreateKey(*oprfKey)
		if err != nil {
			slog.Error("failed to load OPRF key", "err", privlog.Error(err))
			os.Exit(1)
		}
		if err := apiServer.SetOPRF(key); err != nil {
			slog.Error("failed to init blinded discovery", "err", privlog.Error(err))
			os.Exit(1)
		}
		slog.Info("blinded discovery enabled")
	}
	apiHandler := apiServer.Handler()
	go runRateLimiterGC(apiServer)

	// When TLS is enabled, run HTTP/3 (QUIC) on UDP alongside HTTP/2 on TCP.
	// iOS URLSession with assumesHTTP3Capable=true will try QUIC first and fall
	// back to TCP automatically — giving 0-RTT reconnects and no head-of-line
	// blocking in congested networks.
	var h3srv *http3.Server
	servedHandler := apiHandler

	tlsEnabled := *tlsCert != ""
	if tlsEnabled {
		h3srv = &http3.Server{
			Addr:    *addr,
			Handler: apiHandler,
		}
		// Wrap the TCP handler so HTTP/2 responses advertise Alt-Svc: h3,
		// letting any client discover HTTP/3 even without assumesHTTP3Capable.
		inner := apiHandler
		servedHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h3srv.SetQUICHeaders(w.Header()) //nolint:errcheck
			inner.ServeHTTP(w, r)
		})
		go func() {
			slog.Info("http/3 listening", "addr", *addr)
			if err := h3srv.ListenAndServeTLS(*tlsCert, *tlsKey); err != nil {
				slog.Warn("http/3 server stopped", "err", err)
			}
		}()
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           servedHandler,
		ReadHeaderTimeout: 10 * time.Second,
		// Discard stdlib HTTP error logs — they include client IP addresses
		// (e.g. TLS handshake failures from port scanners) which would persist
		// in the systemd journal and be recoverable under a warrant.
		ErrorLog: log.New(io.Discard, "", 0),
	}

	go func() {
		slog.Info("relayd listening", "addr", *addr, "tls", tlsEnabled)
		var err error
		if tlsEnabled {
			err = srv.ListenAndServeTLS(*tlsCert, *tlsKey)
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
	if h3srv != nil {
		h3srv.Close()
	}
	srv.Shutdown(ctx)
	slog.Info("relayd stopped")
}
