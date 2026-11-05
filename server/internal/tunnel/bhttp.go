package tunnel

import (
	"bytes"
	"encoding/binary"
	"strings"
)

// Known-length Binary HTTP (RFC 9292), the subset the app sends: no
// informational responses, trailers always empty, trailing zero padding.

// Request is a decoded inner request.
type Request struct {
	Method, Scheme, Authority, Path string
	Header                          [][2]string // lower-case names
	Body                            []byte
}

// Response is an inner response.
type Response struct {
	Status int
	Header [][2]string
	Body   []byte
}

func appendVarint(b []byte, v uint64) []byte {
	switch {
	case v < 1<<6:
		return append(b, byte(v))
	case v < 1<<14:
		return binary.BigEndian.AppendUint16(b, uint16(v)|0x4000)
	case v < 1<<30:
		return binary.BigEndian.AppendUint32(b, uint32(v)|0x80000000)
	default:
		return binary.BigEndian.AppendUint64(b, v|0xc000000000000000)
	}
}

func appendField(b, v []byte) []byte { return append(appendVarint(b, uint64(len(v))), v...) }

func appendFields(b []byte, fields [][2]string) []byte {
	var section []byte
	for _, f := range fields {
		section = appendField(section, []byte(f[0]))
		section = appendField(section, []byte(f[1]))
	}
	return appendField(b, section)
}

// Encode is the known-length encoding without padding.
func (r *Response) Encode() []byte {
	b := appendVarint(nil, 1) // known-length response
	b = appendVarint(b, uint64(r.Status))
	b = appendFields(b, r.Header)
	b = appendField(b, r.Body)
	return appendVarint(b, 0) // no trailers
}

// Encode is the known-length encoding without padding.
func (r *Request) Encode() []byte {
	b := appendVarint(nil, 0) // known-length request
	for _, s := range []string{r.Method, r.Scheme, r.Authority, r.Path} {
		b = appendField(b, []byte(s))
	}
	b = appendFields(b, r.Header)
	b = appendField(b, r.Body)
	return appendVarint(b, 0)
}

type reader struct{ b []byte }

func (r *reader) varint() (uint64, bool) {
	if len(r.b) == 0 {
		return 0, false
	}
	n := 1 << (r.b[0] >> 6)
	if len(r.b) < n {
		return 0, false
	}
	v := uint64(r.b[0] & 0x3f)
	for _, c := range r.b[1:n] {
		v = v<<8 | uint64(c)
	}
	r.b = r.b[n:]
	return v, true
}

func (r *reader) field() ([]byte, bool) {
	n, ok := r.varint()
	if !ok || n > uint64(len(r.b)) {
		return nil, false
	}
	v := r.b[:n]
	r.b = r.b[n:]
	return v, true
}

func (r *reader) fields() ([][2]string, bool) {
	section, ok := r.field()
	if !ok {
		return nil, false
	}
	s := reader{section}
	var out [][2]string
	for len(s.b) > 0 {
		name, ok1 := s.field()
		value, ok2 := s.field()
		if !ok1 || !ok2 {
			return nil, false
		}
		out = append(out, [2]string{strings.ToLower(string(name)), string(value)})
	}
	return out, true
}

// rest is padding: zeros only.
func (r *reader) onlyPadding() bool { return len(bytes.Trim(r.b, "\x00")) == 0 }

// DecodeRequest parses a padded known-length request.
func DecodeRequest(b []byte) (*Request, error) {
	r := reader{b}
	if f, ok := r.varint(); !ok || f != 0 {
		return nil, ErrMalformed
	}
	var parts [4][]byte
	for i := range parts {
		v, ok := r.field()
		if !ok {
			return nil, ErrMalformed
		}
		parts[i] = v
	}
	header, ok := r.fields()
	if !ok {
		return nil, ErrMalformed
	}
	body, ok := r.field()
	if !ok {
		return nil, ErrMalformed
	}
	// Trailers: tolerate a missing section (it may be truncated with padding).
	if len(r.b) > 0 {
		if _, ok := r.fields(); !ok {
			return nil, ErrMalformed
		}
	}
	if !r.onlyPadding() {
		return nil, ErrMalformed
	}
	return &Request{
		Method: string(parts[0]), Scheme: string(parts[1]), Authority: string(parts[2]), Path: string(parts[3]),
		Header: header, Body: body,
	}, nil
}

// DecodeResponse parses a padded known-length response (used by tests).
func DecodeResponse(b []byte) (*Response, error) {
	r := reader{b}
	if f, ok := r.varint(); !ok || f != 1 {
		return nil, ErrMalformed
	}
	status, ok := r.varint()
	if !ok || status < 200 || status > 599 {
		return nil, ErrMalformed
	}
	header, ok := r.fields()
	if !ok {
		return nil, ErrMalformed
	}
	body, ok := r.field()
	if !ok {
		return nil, ErrMalformed
	}
	if len(r.b) > 0 {
		if _, ok := r.fields(); !ok {
			return nil, ErrMalformed
		}
	}
	if !r.onlyPadding() {
		return nil, ErrMalformed
	}
	return &Response{Status: int(status), Header: header, Body: body}, nil
}
