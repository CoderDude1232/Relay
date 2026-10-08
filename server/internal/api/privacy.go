package api

import (
	"net/http"
	"strings"
	"time"
)

const (
	defaultMaxRequestBodySize    = 1 << 20
	attachmentMaxRequestBodySize = 26 << 20
)

var visitorIPHeaders = []string{
	"CF-Connecting-IP",
	"CF-Connecting-IPv6",
	"True-Client-IP",
	"X-Forwarded-For",
	"X-Real-IP",
	"Forwarded",
}

func stripVisitorIPHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, header := range visitorIPHeaders {
			r.Header.Del(header)
		}
		next.ServeHTTP(w, r)
	})
}

// Per-request I/O deadlines. The http.Server can't use a blanket ReadTimeout /
// WriteTimeout because the WebSocket upgrade is long-lived, so each request
// sets its own via http.ResponseController: short for ordinary JSON calls (a
// slow-loris body can't pin a goroutine/connection), long for attachment
// transfers, none for the WebSocket.
const (
	requestReadTimeout     = 30 * time.Second
	requestWriteTimeout    = 60 * time.Second
	attachmentIOTimeout    = 10 * time.Minute
	webSocketUpgradePrefix = "/v1/ws"
)

func requestDeadlines(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rc := http.NewResponseController(w)
		var read, write time.Time
		switch {
		case r.URL.Path == webSocketUpgradePrefix:
			// Zero = no deadline; also clears one left over from an earlier
			// request on this keep-alive connection. The WS pumps manage
			// their own deadlines after the upgrade.
		case strings.HasPrefix(r.URL.Path, "/v1/attachments/"):
			read = time.Now().Add(attachmentIOTimeout)
			write = read
		default:
			read = time.Now().Add(requestReadTimeout)
			write = time.Now().Add(requestWriteTimeout)
		}
		// Errors (e.g. ErrNotSupported on HTTP/3) are ignored: the deadline is
		// a hardening measure, not a correctness requirement.
		_ = rc.SetReadDeadline(read)
		_ = rc.SetWriteDeadline(write)
		next.ServeHTTP(w, r)
	})
}

func limitRequestBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil {
			limit := int64(defaultMaxRequestBodySize)
			if r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/v1/attachments/") {
				limit = attachmentMaxRequestBodySize
			}
			r.Body = http.MaxBytesReader(w, r.Body, limit)
		}
		next.ServeHTTP(w, r)
	})
}
