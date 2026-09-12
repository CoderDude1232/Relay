package api

import (
	"net/http"
	"strings"
)

const (
	defaultMaxRequestBodySize = 1 << 20
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
