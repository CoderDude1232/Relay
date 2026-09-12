// Package privlog provides small helpers for privacy-preserving operational
// logs. It should be used before errors or untrusted values reach slog.
package privlog

import (
	"regexp"
)

const redacted = "<redacted>"

var sensitivePatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\bbearer\s+[^\s,;]+`),
	regexp.MustCompile(`(?i)(authorization|bearer|basic|password|token|secret|nonce|key|credential)=([^\s,;]+)`),
	regexp.MustCompile(`(?i)(authorization|bearer|basic|password|token|secret|nonce|key|credential)(["':\s=]+)([^\s,;}]+)`),
	regexp.MustCompile(`\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b`),
	regexp.MustCompile(`\b[0-9a-fA-F]{32,}\b`),
	regexp.MustCompile(`\b[A-Za-z0-9+/]{48,}={0,2}\b`),
}

func String(value string) string {
	out := value
	for _, pattern := range sensitivePatterns {
		out = pattern.ReplaceAllString(out, redacted)
	}
	return out
}

func Error(err error) string {
	if err == nil {
		return ""
	}
	return String(err.Error())
}
