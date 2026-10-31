package api

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/blob"
)

func newAttachmentTestServer(t *testing.T, maxBlob, dailyBytes, diskCap int64) *Server {
	t.Helper()
	for _, l := range allLimiters {
		l.reset()
	}
	blobs, err := blob.Open(filepath.Join(t.TempDir(), "blobs"), maxBlob)
	if err != nil {
		t.Fatal(err)
	}
	s := New(nil, nil, blobs, "", "")
	s.SetAttachmentQuota(dailyBytes, 1000)
	s.SetAttachmentDiskCap(diskCap)
	return s
}

// allocID reserves a blob id, recording account as its owner ("" = no owner
// record, as for ids allocated before a restart).
func allocID(t *testing.T, s *Server, account string) string {
	t.Helper()
	id, _ := s.blobs.NewID()
	if account != "" && !s.attachQuota.allocate(account, id) {
		t.Fatal("allocate refused")
	}
	if err := s.blobs.Reserve(id); err != nil {
		t.Fatal(err)
	}
	return id
}

func putAttachment(s *Server, id string, body io.Reader, contentLength int64) int {
	req := httptest.NewRequest("PUT", "/v1/attachments/"+id, body)
	req.ContentLength = contentLength
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec.Code
}

// startStalledUpload begins an upload whose body blocks until the returned
// writer is closed, and waits until its reservation is held.
func startStalledUpload(t *testing.T, s *Server, id string, n int64) (pw *io.PipeWriter, done <-chan int) {
	t.Helper()
	before := s.attachInFlight.load()
	pr, pw := io.Pipe()
	ch := make(chan int, 1)
	go func() { ch <- putAttachment(s, id, pr, n) }()
	deadline := time.Now().Add(5 * time.Second)
	for s.attachInFlight.load() < before+n {
		if time.Now().After(deadline) {
			t.Fatal("upload never reserved")
		}
		time.Sleep(time.Millisecond)
	}
	return pw, ch
}

// An in-progress upload holds its full size against the owner's byte budget,
// so a parallel upload can't spend the same bytes; the unused part comes back
// afterwards.
func TestParallelUploadsReserveByteBudget(t *testing.T) {
	s := newAttachmentTestServer(t, 1<<20, 1000, 0)
	first := allocID(t, s, "acct")
	pw, done := startStalledUpload(t, s, first, 600)

	if got := putAttachment(s, allocID(t, s, "acct"), bytes.NewReader(make([]byte, 600)), 600); got != http.StatusTooManyRequests {
		t.Fatalf("parallel upload over budget: got %d, want 429", got)
	}
	// Another account is unaffected.
	if got := putAttachment(s, allocID(t, s, "other"), bytes.NewReader(make([]byte, 600)), 600); got != http.StatusNoContent {
		t.Fatalf("other account: got %d, want 204", got)
	}

	// The stalled upload stores only 100 of its reserved 600 bytes; the other
	// 500 come back, leaving 900.
	pw.Write(make([]byte, 100))
	pw.Close()
	if got := <-done; got != http.StatusNoContent {
		t.Fatalf("stalled upload: got %d, want 204", got)
	}
	if got := putAttachment(s, allocID(t, s, "acct"), bytes.NewReader(make([]byte, 600)), 600); got != http.StatusNoContent {
		t.Fatalf("upload after refund: got %d, want 204", got)
	}
	// 300 bytes left: a 600-byte upload is refused, a 300-byte one fits.
	if got := putAttachment(s, allocID(t, s, "acct"), bytes.NewReader(make([]byte, 600)), 600); got != http.StatusTooManyRequests {
		t.Fatalf("upload over remaining budget: got %d, want 429", got)
	}
	if got := putAttachment(s, allocID(t, s, "acct"), bytes.NewReader(make([]byte, 300)), 300); got != http.StatusNoContent {
		t.Fatalf("upload within remaining budget: got %d, want 204", got)
	}
}

// Many concurrent uploads from one account never store more than its budget.
func TestConcurrentUploadsCannotExceedBudget(t *testing.T) {
	const budget, size, uploads = 10_000, 1000, 50
	s := newAttachmentTestServer(t, 1<<20, budget, 0)
	ids := make([]string, uploads)
	for i := range ids {
		ids[i] = allocID(t, s, "acct")
	}
	var stored atomic.Int64
	var wg sync.WaitGroup
	start := make(chan struct{})
	for _, id := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			if putAttachment(s, id, bytes.NewReader(make([]byte, size)), size) == http.StatusNoContent {
				stored.Add(size)
			}
		}()
	}
	close(start)
	wg.Wait()
	if got := stored.Load(); got > budget || got == 0 {
		t.Fatalf("stored %d bytes, want 1..%d", got, budget)
	}
	if got := s.blobs.Usage(); got != stored.Load() {
		t.Fatalf("disk usage %d != stored %d", got, stored.Load())
	}
}

// A body without Content-Length reserves the most the upload may store.
func TestChunkedUploadReservesRequestLimit(t *testing.T) {
	s := newAttachmentTestServer(t, 1<<20, 1<<20, 0)
	if got := putAttachment(s, allocID(t, s, "acct"), bytes.NewReader(make([]byte, 10)), -1); got != http.StatusTooManyRequests {
		t.Fatalf("chunked upload with less than the request limit left: got %d, want 429", got)
	}
}

// In-flight uploads count toward the disk watermark.
func TestInFlightUploadsCountTowardDiskCap(t *testing.T) {
	s := newAttachmentTestServer(t, 1<<20, 1<<30, 1000)
	pw, done := startStalledUpload(t, s, allocID(t, s, "a"), 600)
	second := allocID(t, s, "b")
	if got := putAttachment(s, second, bytes.NewReader(make([]byte, 600)), 600); got != http.StatusInsufficientStorage {
		t.Fatalf("upload past the cap with one in flight: got %d, want 507", got)
	}
	pw.Write(make([]byte, 600))
	pw.Close()
	if got := <-done; got != http.StatusNoContent {
		t.Fatalf("stalled upload: got %d, want 204", got)
	}
	if got := s.attachInFlight.load(); got != 0 {
		t.Fatalf("in-flight after completion = %d, want 0", got)
	}
	// The refused upload kept its reservation; 400 bytes of room remain.
	if got := putAttachment(s, second, bytes.NewReader(make([]byte, 400)), 400); got != http.StatusNoContent {
		t.Fatalf("retry within remaining room: got %d, want 204", got)
	}
}

// Ids with no allocation record (allocated before a restart) share one
// account-sized budget instead of uploading uncharged.
func TestUnknownOwnerUploadsShareOneBudget(t *testing.T) {
	s := newAttachmentTestServer(t, 1<<20, 1000, 0)
	if got := putAttachment(s, allocID(t, s, ""), bytes.NewReader(make([]byte, 600)), 600); got != http.StatusNoContent {
		t.Fatalf("first unknown-owner upload: got %d, want 204", got)
	}
	if got := putAttachment(s, allocID(t, s, ""), bytes.NewReader(make([]byte, 600)), 600); got != http.StatusTooManyRequests {
		t.Fatalf("second unknown-owner upload: got %d, want 429", got)
	}
}

// A rejected (too large) upload refunds its whole reservation.
func TestFailedUploadRefundsReservation(t *testing.T) {
	s := newAttachmentTestServer(t, 500, 1000, 0)
	if got := putAttachment(s, allocID(t, s, "acct"), bytes.NewReader(make([]byte, 900)), 900); got != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized upload: got %d, want 413", got)
	}
	if got := putAttachment(s, allocID(t, s, "acct"), bytes.NewReader(make([]byte, 500)), 900); got == http.StatusTooManyRequests {
		t.Fatal("budget not refunded after a failed upload")
	}
}
