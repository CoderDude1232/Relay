package api

import (
	"net/http"
	"sync/atomic"
)

// attachmentUploadReservation is how many bytes an upload reserves from the
// owner's byte budget and the disk watermark before it starts: the declared
// Content-Length (the server never reads past it) or, for a chunked body, the
// request body limit. Unused bytes are refunded when the upload ends.
func attachmentUploadReservation(r *http.Request) int64 {
	n := int64(attachmentMaxRequestBodySize)
	if r.ContentLength >= 0 && r.ContentLength < n {
		n = r.ContentLength
	}
	return n
}

// attachmentInFlight counts bytes reserved by uploads still being written, so
// the disk watermark covers temp files and not just finished blobs.
type attachmentInFlight struct{ n atomic.Int64 }

// reserve takes n bytes of disk headroom; false (taking nothing) when the
// finished blobs plus in-flight reservations would pass capBytes. A cap of 0
// is unlimited.
func (f *attachmentInFlight) reserve(n, usage, capBytes int64) bool {
	total := f.n.Add(n)
	if capBytes > 0 && usage+total > capBytes {
		f.n.Add(-n)
		return false
	}
	return true
}

func (f *attachmentInFlight) release(n int64) { f.n.Add(-n) }

func (f *attachmentInFlight) load() int64 { return f.n.Load() }
