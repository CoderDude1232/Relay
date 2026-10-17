package api

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/relayapp/relay-server/internal/history"
)

func TestStripVisitorIPHeaders(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, header := range visitorIPHeaders {
			if got := r.Header.Get(header); got != "" {
				t.Fatalf("%s was not stripped: %q", header, got)
			}
		}
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/accounts/me", nil)
	for _, header := range visitorIPHeaders {
		req.Header.Set(header, "203.0.113.9")
	}
	rr := httptest.NewRecorder()

	stripVisitorIPHeaders(inner).ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusNoContent)
	}
}

func TestLimitRequestBody(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, err := io.ReadAll(r.Body)
		if err == nil {
			t.Fatal("expected oversized body read to fail")
		}
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/accounts", strings.NewReader(strings.Repeat("a", defaultMaxRequestBodySize+1)))
	rr := httptest.NewRecorder()

	limitRequestBody(inner).ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusNoContent)
	}
}

func TestHistorySegmentBodyLimit(t *testing.T) {
	var read int
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("a 2 MiB segment body was cut off: %v", err)
		}
		read = len(b)
		w.WriteHeader(http.StatusNoContent)
	})
	full := strings.Repeat("a", history.MaxSegmentBytes)
	rr := httptest.NewRecorder()
	limitRequestBody(inner).ServeHTTP(rr, httptest.NewRequest(http.MethodPut, "/v1/history/1", strings.NewReader(full)))
	if rr.Code != http.StatusNoContent || read != history.MaxSegmentBytes {
		t.Fatalf("2 MiB segment: status %d, read %d", rr.Code, read)
	}
	// A declared length over the cap is refused before anything reads it.
	rr = httptest.NewRecorder()
	limitRequestBody(inner).ServeHTTP(rr, httptest.NewRequest(http.MethodPut, "/v1/history/1", strings.NewReader(full+"a")))
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized segment: status %d, want 413", rr.Code)
	}
}
