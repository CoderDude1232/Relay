package api

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/relayapp/relay-server/internal/history"
	"github.com/relayapp/relay-server/internal/privlog"
	"github.com/relayapp/relay-server/internal/store"
)

// Chat-history backup: the client uploads numbered, encrypted segments of its
// message history; a new device downloads the latest complete snapshot. The
// relay stores opaque blobs (internal/history) and one row per segment.

// maxHistorySeq is 2^53, so every seq survives a round trip through a double.
const maxHistorySeq = 1 << 53

var (
	historyPutLimiter    = newSlidingWindowLimiter(600, time.Hour)
	historyGetLimiter    = newSlidingWindowLimiter(600, time.Hour)
	historyDeleteLimiter = newSlidingWindowLimiter(600, time.Hour)
)

// historyOrphanGrace keeps the sweeper away from blobs whose upload is still
// between writing the blob and committing its row.
const historyOrphanGrace = time.Hour

// historyBlobTimeout bounds best-effort blob deletions after a request.
const historyBlobTimeout = 2 * time.Minute

// SetHistory enables the history backup routes with st as blob storage.
func (s *Server) SetHistory(st *history.Storage) { s.history = st }

// parseHistorySeq accepts only canonical decimals in 1..2^53.
func parseHistorySeq(r *http.Request) (int64, bool) {
	raw := r.PathValue("seq")
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 1 || n > maxHistorySeq || strconv.FormatInt(n, 10) != raw {
		return 0, false
	}
	return n, true
}

// GET /v1/history → {segments:[{seq,size}], usedBytes, maxBytes}.
func (s *Server) handleListHistory(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if !historyGetLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	segs, used, err := s.store.HistorySegments(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	type entry struct {
		Seq  int64 `json:"seq"`
		Size int   `json:"size"`
	}
	out := make([]entry, len(segs))
	for i, h := range segs {
		out[i] = entry{Seq: h.Seq, Size: h.Size}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"segments": out, "usedBytes": used, "maxBytes": store.MaxHistoryBytes,
	})
}

// PUT /v1/history/{seq}: raw segment bytes → 204.
func (s *Server) handlePutHistory(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !historyPutLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many uploads; try again later")
		return
	}
	seq, ok := parseHistorySeq(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "seq must be a decimal in 1..2^53")
		return
	}
	if s.refuseIfDemo(w, dev.AccountID) {
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, history.MaxSegmentBytes+1))
	if err != nil {
		httpError(w, http.StatusBadRequest, "could not read body")
		return
	}
	if len(body) > history.MaxSegmentBytes {
		httpError(w, http.StatusRequestEntityTooLarge, "segment over 2 MiB")
		return
	}
	if len(body) == 0 {
		httpError(w, http.StatusBadRequest, "empty segment")
		return
	}
	if s.history == nil {
		httpError(w, http.StatusInsufficientStorage, "history storage unavailable")
		return
	}
	if err := s.store.CheckHistoryQuota(dev.AccountID, seq, len(body)); errors.Is(err, store.ErrHistoryQuota) {
		httpError(w, http.StatusInsufficientStorage, "history quota exceeded")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	key := s.history.Key(dev.AccountID, seq)
	loc, err := s.history.Put(r.Context(), key, body)
	if err != nil {
		httpError(w, http.StatusInsufficientStorage, "history storage unavailable")
		return
	}
	prev, err := s.store.PutHistorySegment(dev.AccountID, seq, len(body), string(loc))
	if err != nil {
		// The blob is unreferenced unless a row for this seq already points at
		// the same location (a replace writes over the old file in place).
		if cur, lookupErr := s.store.HistorySegment(dev.AccountID, seq); lookupErr != nil || cur.Location != string(loc) {
			s.deleteHistoryBlob(dev.AccountID, store.HistorySegment{Seq: seq, Location: string(loc)})
		}
		switch {
		case errors.Is(err, store.ErrHistoryQuota):
			httpError(w, http.StatusInsufficientStorage, "history quota exceeded")
		case errors.Is(err, store.ErrNotFound):
			httpError(w, http.StatusNotFound, "no such account")
		default:
			internalError(w, err)
		}
		return
	}
	// Same key in the same place was overwritten; elsewhere, the old copy goes.
	if prev != nil && prev.Location != string(loc) {
		s.deleteHistoryBlob(dev.AccountID, *prev)
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/history/{seq} → raw segment bytes, or 404.
func (s *Server) handleGetHistory(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !historyGetLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	seq, ok := parseHistorySeq(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "seq must be a decimal in 1..2^53")
		return
	}
	seg, err := s.store.HistorySegment(dev.AccountID, seq)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such segment")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	if s.history == nil {
		httpError(w, http.StatusServiceUnavailable, "history storage unavailable")
		return
	}
	data, err := s.history.Get(r.Context(), history.Location(seg.Location), s.history.Key(dev.AccountID, seq))
	if errors.Is(err, history.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such segment")
		return
	}
	if err != nil {
		slog.Warn("history: segment read failed", "location", seg.Location, "err", privlog.Error(err))
		httpError(w, http.StatusServiceUnavailable, "history storage unavailable; try again later")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(data)
}

// DELETE /v1/history/{seq} → 204, whether or not it existed.
func (s *Server) handleDeleteHistorySegment(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !historyDeleteLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	seq, ok := parseHistorySeq(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "seq must be a decimal in 1..2^53")
		return
	}
	prev, err := s.store.DeleteHistorySegment(dev.AccountID, seq)
	if err != nil {
		internalError(w, err)
		return
	}
	if prev != nil {
		s.deleteHistoryBlob(dev.AccountID, *prev)
	}
	w.WriteHeader(http.StatusNoContent)
}

// DELETE /v1/history → 204; removes every segment.
func (s *Server) handleDeleteHistory(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if !historyDeleteLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	segs, err := s.store.DeleteHistory(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	s.dropHistoryBlobs(dev.AccountID, segs)
	w.WriteHeader(http.StatusNoContent)
}

// deleteHistoryBlob deletes one blob, best effort; the sweeper catches
// failures.
func (s *Server) deleteHistoryBlob(accountID string, seg store.HistorySegment) {
	if s.history == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), historyBlobTimeout)
	defer cancel()
	if err := s.history.Delete(ctx, history.Location(seg.Location), s.history.Key(accountID, seg.Seq)); err != nil {
		slog.Warn("history: blob delete failed; the sweeper will retry", "location", seg.Location, "err", privlog.Error(err))
	}
}

// dropHistoryBlobs deletes the blobs of rows already removed, in the
// background: there can be hundreds, and remote deletes take a round trip each.
func (s *Server) dropHistoryBlobs(accountID string, segs []store.HistorySegment) {
	if s.history == nil || len(segs) == 0 {
		return
	}
	go func() {
		for _, seg := range segs {
			s.deleteHistoryBlob(accountID, seg)
		}
	}()
}

// SweepHistory deletes blobs that no row refers to. relayd runs it hourly.
func (s *Server) SweepHistory(ctx context.Context) {
	if s.history == nil {
		return
	}
	refs, err := s.store.AllHistoryBlobs()
	if err != nil {
		slog.Warn("history sweep: listing rows failed", "err", privlog.Error(err))
		return
	}
	live := map[history.Location]map[string]bool{history.Local: {}, history.Remote: {}}
	for _, ref := range refs {
		if m := live[history.Location(ref.Location)]; m != nil {
			m[s.history.Key(ref.AccountID, ref.Seq)] = true
		}
	}
	s.history.Sweep(ctx, live, historyOrphanGrace)
}
