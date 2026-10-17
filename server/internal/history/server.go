package history

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/relayapp/relay-server/internal/privlog"
)

// MinDiskFree is the free space historyd keeps on its filesystem: below it,
// writes get 507.
const MinDiskFree = 1 << 30

// BlobServer is historyd's HTTP API. Every request must carry a valid
// AuthHeader; only relayd holds the secret.
type BlobServer struct {
	store    *DirStore
	secret   []byte
	maxBytes int64 // 0 = no cap beyond MinDiskFree

	freeBytes func(dir string) (int64, error)
	now       func() time.Time
}

func NewBlobServer(store *DirStore, secret []byte, maxBytes int64) *BlobServer {
	return &BlobServer{store: store, secret: secret, maxBytes: maxBytes, freeBytes: FreeBytes, now: time.Now}
}

func (s *BlobServer) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("PUT /v1/blob/{key}", s.authed(s.handlePut))
	mux.HandleFunc("GET /v1/blob/{key}", s.authed(s.handleGet))
	mux.HandleFunc("DELETE /v1/blob/{key}", s.authed(s.handleDelete))
	mux.HandleFunc("GET /v1/blobs", s.authed(s.handleList))
	mux.HandleFunc("GET /health", s.authed(s.handleHealth))
	return mux
}

// authed reads the body (at most one segment) and checks the MAC over it
// before the handler runs.
func (s *BlobServer) authed(next func(http.ResponseWriter, *http.Request, []byte)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get(AuthHeader)
		if header == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxSegmentBytes))
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			http.Error(w, "blob too large", http.StatusRequestEntityTooLarge)
			return
		}
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if VerifyRequest(s.secret, header, r.Method, r.URL.Path, body, s.now()) != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r, body)
	}
}

// room is how many more bytes may be written: the smaller of what -max-bytes
// and the free-disk floor leave.
func (s *BlobServer) room() (int64, error) {
	free, err := s.freeBytes(s.store.Dir())
	if err != nil {
		return 0, err
	}
	room := free - MinDiskFree
	if s.maxBytes > 0 {
		room = min(room, s.maxBytes-s.store.Usage())
	}
	return max(room, 0), nil
}

func (s *BlobServer) handlePut(w http.ResponseWriter, r *http.Request, body []byte) {
	key := r.PathValue("key")
	if !ValidKey(key) || len(body) == 0 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	room, err := s.room()
	if err != nil {
		slog.Error("historyd: free space unknown", "err", privlog.Error(err))
		http.Error(w, "storage unavailable", http.StatusInsufficientStorage)
		return
	}
	// A replace frees the old blob's bytes.
	if int64(len(body))-s.store.Size(key) > room {
		http.Error(w, "storage full", http.StatusInsufficientStorage)
		return
	}
	if err := s.store.Put(key, body); err != nil {
		slog.Error("historyd: write failed", "err", privlog.Error(err))
		http.Error(w, "storage unavailable", http.StatusInsufficientStorage)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *BlobServer) handleGet(w http.ResponseWriter, r *http.Request, _ []byte) {
	data, err := s.store.Get(r.PathValue("key"))
	if errors.Is(err, ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		slog.Error("historyd: read failed", "err", privlog.Error(err))
		http.Error(w, "read failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

func (s *BlobServer) handleDelete(w http.ResponseWriter, r *http.Request, _ []byte) {
	key := r.PathValue("key")
	if !ValidKey(key) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err := s.store.Delete(key); err != nil {
		slog.Error("historyd: delete failed", "err", privlog.Error(err))
		http.Error(w, "delete failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *BlobServer) handleList(w http.ResponseWriter, _ *http.Request, _ []byte) {
	list, err := s.store.List()
	if err != nil {
		slog.Error("historyd: list failed", "err", privlog.Error(err))
		http.Error(w, "list failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"blobs": list})
}

func (s *BlobServer) handleHealth(w http.ResponseWriter, _ *http.Request, _ []byte) {
	room, err := s.room()
	if err != nil {
		slog.Error("historyd: free space unknown", "err", privlog.Error(err))
		http.Error(w, "storage unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int64{"freeBytes": room, "usedBytes": s.store.Usage()})
}
