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
	"strings"
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
	"github.com/relayapp/relay-server/internal/siwa"
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

// runRetentionSweeper deletes expired rows from every table with a retention
// window (queue, invites, provisioning sessions, link tokens, reports, nuke
// commands) at startup and then hourly, and prunes the hub's in-memory
// bookkeeping.
func runRetentionSweeper(st *store.Store, h *hub.Hub) {
	sweep := func() {
		if err := st.PurgeExpired(); err != nil {
			slog.Warn("retention sweep failed", "err", privlog.Error(err))
		}
		h.Prune(store.QueueTTL)
	}
	sweep()
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for range ticker.C {
		sweep()
	}
}

// envOr returns the environment variable's value, or def when it's unset or empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// parseLogLevel maps the -log-level flag to a slog level.
func parseLogLevel(v string) (slog.Level, error) {
	var l slog.Level
	err := l.UnmarshalText([]byte(v))
	return l, err
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
	// Secrets can come from the environment (e.g. a root-only systemd
	// EnvironmentFile) so they never appear in the unit file or in ps.
	// No built-in default: a guessable relay:relay DSN must never be what a
	// misconfigured deployment silently falls back to.
	dsn := flag.String("dsn", envOr("RELAY_DSN", ""), "PostgreSQL DSN (required; default $RELAY_DSN)")
	tlsCert := flag.String("tls-cert", "", "path to TLS certificate (enables HTTPS/WSS)")
	tlsKey := flag.String("tls-key", "", "path to TLS private key")
	blobDir := flag.String("blobs", "attachments", "directory for encrypted attachment blobs")
	maxAttachment := flag.Int64("max-attachment", 25<<20, "max attachment blob size in bytes")
	blobTTL := flag.Duration("attachment-ttl", 14*24*time.Hour, "how long to keep attachment blobs")
	attachDailyBytes := flag.Int64("attachment-daily-bytes", 2<<30, "per-account attachment upload budget in bytes per rolling day")
	attachDailyCount := flag.Int("attachment-daily-count", 1000, "per-account attachment allocations per rolling day")
	attachDiskCap := flag.Int64("attachment-disk-cap", api.DefaultAttachmentDiskCap, "global attachment disk watermark in bytes: new allocations/uploads get 507 once the blob directory holds this much (0 = unlimited)")
	logLevel := flag.String("log-level", "warn", "minimum log level: debug, info, warn or error (per-connection/per-message events are debug)")
	apnsKey := flag.String("apns-key", "", "path to APNs .p8 auth key (enables push)")
	apnsKeyID := flag.String("apns-key-id", "", "APNs key id")
	apnsTeamID := flag.String("apns-team-id", "", "Apple team id")
	apnsTopic := flag.String("apns-topic", "app.relaymsg", "APNs topic (app bundle id)")
	apnsProduction := flag.Bool("apns-production", false, "use the APNs production host (default: sandbox)")
	trustedProxies := flag.String("trusted-proxies", "", "honour CF-Connecting-IP only from these proxies: \"cloudflare\" (built-in Cloudflare ranges) or comma-separated CIDRs; empty = never")
	siwaKey := flag.String("siwa-key", "", "path to a Sign in with Apple .p8 key (enables revoking the user's Apple grant on DELETE /v1/accounts/me)")
	siwaKeyID := flag.String("siwa-key-id", "", "Sign in with Apple key id")
	siwaTeamID := flag.String("siwa-team-id", "", "Apple team id for Sign in with Apple (default: -apns-team-id)")
	siwaClientID := flag.String("siwa-client-id", "app.relaymsg", "Sign in with Apple client id (the app's bundle id)")
	fcmServiceAccount := flag.String("fcm-service-account", "", "path to a Firebase service-account JSON key (enables FCM push for Android devices)")
	turnURLs := flag.String("turn-urls", "", "comma-separated TURN server URLs (enables dynamic TURN credentials)")
	turnSecret := flag.String("turn-secret", os.Getenv("RELAY_TURN_SECRET"), "shared HMAC-SHA1 secret for coturn REST API credential generation (default $RELAY_TURN_SECRET)")
	turnStatusURL := flag.String("turn-status-url", "", "turnload agent URL on the TURN box (e.g. http://turn.example:9478/status); with -cloudflare-turn-key-id, calls fail over to Cloudflare before coturn is overloaded")
	cfTURNKeyID := flag.String("cloudflare-turn-key-id", "", "Cloudflare Realtime TURN key id (enables failover to Cloudflare TURN when our coturn is down or overloaded)")
	cfTURNTokenFile := flag.String("cloudflare-turn-token-file", "", "path to a file holding the Cloudflare TURN key's API token")
	demoCodeFile := flag.String("demo-code-file", "", "path to a file holding the App Review sign-in code (enables POST /v1/accounts/demo-signin)")
	supabaseURL := flag.String("supabase-url", "", "Supabase project URL (enables social-login account recovery via POST /v1/accounts/oauth)")
	supabaseAnonKey := flag.String("supabase-anon-key", "", "Supabase anon API key (sent as the apikey header when verifying user tokens)")
	supabaseServiceKeyFile := flag.String("supabase-service-key-file", "", "path to a file holding the Supabase service-role key (enables deleting the Supabase auth user on account deletion)")
	sealedKey := flag.String("sealed-sender-trust-key", "", "path to the sealed-sender trust-root private key (hex, 32 bytes); generated if absent, enables GET /v1/certificate/delivery")
	oprfKey := flag.String("oprf-key", "", "path to the blinded-discovery OPRF secret key (hex ristretto255 scalar); generated if absent, enables /v1/directory/*")
	passkeyRPID := flag.String("passkey-rp-id", api.DefaultPasskeyRPID, "WebAuthn relying party ID for passkey sign-in")
	passkeyOrigins := flag.String("passkey-origins", api.DefaultPasskeyOrigin, "comma-separated origins accepted in passkey clientDataJSON")
	flag.Parse()

	level, err := parseLogLevel(*logLevel)
	if err != nil {
		slog.Error("invalid -log-level", "value", *logLevel)
		os.Exit(1)
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))

	if *dsn == "" {
		slog.Error("no database configured: pass -dsn or set RELAY_DSN (e.g. postgres:///relay?host=/var/run/postgresql)")
		os.Exit(1)
	}
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
	go runRetentionSweeper(st, h)
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
	if *demoCodeFile != "" {
		code, err := os.ReadFile(*demoCodeFile)
		if err != nil {
			slog.Error("read demo code", "err", err)
			os.Exit(1)
		}
		apiServer.SetDemoCode(string(code))
		slog.Info("review-code demo sign-in enabled")
	}
	if *cfTURNKeyID != "" {
		token, err := os.ReadFile(*cfTURNTokenFile)
		if err != nil {
			slog.Error("read cloudflare turn token", "err", err)
			os.Exit(1)
		}
		probeAddr := turnProbeAddr(*turnURLs)
		if probeAddr == "" {
			slog.Error("-cloudflare-turn-key-id needs a turn: URL in -turn-urls to health-check")
			os.Exit(1)
		}
		health := api.NewTURNHealth(probeAddr, *turnStatusURL)
		go health.Run(context.Background())
		apiServer.SetTURNFailover(health, &api.CloudflareTURN{
			KeyID: *cfTURNKeyID, APIToken: strings.TrimSpace(string(token)),
		})
		slog.Info("turn failover to cloudflare enabled", "probe", probeAddr, "status", *turnStatusURL)
	}
	var origins []string
	for _, o := range strings.Split(*passkeyOrigins, ",") {
		if o = strings.TrimSpace(o); o != "" {
			origins = append(origins, o)
		}
	}
	if err := apiServer.SetPasskeyRP(*passkeyRPID, origins); err != nil {
		slog.Error("invalid passkey config", "err", err)
		os.Exit(1)
	}
	apiServer.SetAttachmentQuota(*attachDailyBytes, *attachDailyCount)
	apiServer.SetAttachmentDiskCap(*attachDiskCap)
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
	if err := api.SetTrustedProxies(*trustedProxies); err != nil {
		slog.Error("invalid -trusted-proxies", "err", err)
		os.Exit(1)
	}
	if *siwaKey != "" {
		teamID := *siwaTeamID
		if teamID == "" {
			teamID = *apnsTeamID
		}
		revoker, err := siwa.New(*siwaKey, *siwaKeyID, teamID, *siwaClientID)
		if err != nil {
			slog.Error("failed to load Sign in with Apple key", "err", privlog.Error(err))
			os.Exit(1)
		}
		apiServer.SetAppleRevoker(revoker)
		slog.Info("sign in with apple token revocation enabled", "clientId", *siwaClientID)
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
	} else {
		slog.Warn("no -oprf-key: blinded discovery, email features and the 7-day username reuse cooldown are disabled")
	}
	apiHandler := apiServer.Handler()
	go runRateLimiterGC(apiServer)

	// With TLS, serve HTTP/3 (QUIC) on UDP alongside HTTP/2 on TCP. Clients
	// with assumesHTTP3Capable try QUIC first and fall back to TCP.
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
		// No blanket ReadTimeout/WriteTimeout: the WebSocket is long-lived.
		// Ordinary requests get per-request deadlines from the API handler
		// (30 s read / 60 s write; 10 min for attachment transfers).
		IdleTimeout:    120 * time.Second,
		MaxHeaderBytes: 16 << 10,
		// Discard stdlib HTTP error logs: they include client IP addresses
		// (e.g. TLS handshake failures from scanners), which would otherwise
		// persist in the systemd journal.
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

// turnProbeAddr returns host:port of the first plain turn: URL (UDP), for the
// health prober.
func turnProbeAddr(urls string) string {
	for _, u := range strings.Split(urls, ",") {
		u = strings.TrimSpace(u)
		if !strings.HasPrefix(u, "turn:") {
			continue
		}
		hostport := strings.TrimPrefix(u, "turn:")
		if i := strings.IndexByte(hostport, '?'); i >= 0 {
			hostport = hostport[:i]
		}
		if !strings.Contains(hostport, ":") {
			hostport += ":3478"
		}
		return hostport
	}
	return ""
}
