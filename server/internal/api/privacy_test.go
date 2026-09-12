package api

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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
