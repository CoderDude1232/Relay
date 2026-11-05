// Package tunnel carries the app's requests to relayd encrypted to a key only
// relayd holds, so the TLS-terminating proxy in front of it (Cloudflare) sees
// an opaque POST /v1/t of padded size instead of paths, headers and bodies.
//
// A request is an Oblivious HTTP message (RFC 9458) wrapping a known-length
// Binary HTTP message (RFC 9292), with the ciphersuite X-Wing
// (ML-KEM-768 + X25519), HKDF-SHA256, AES-256-GCM. The WebSocket variant opens
// with one such request and then exchanges frames under keys exported from the
// same HPKE context (see Stream). See docs/TUNNEL.md.
package tunnel

import (
	"crypto/hkdf"
	"crypto/hpke"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
)

// KeyID names the key in the request header; the app builds in the public
// half for each id it accepts.
const KeyID = 1

const (
	kemID  = 0x647a // MLKEM768-X25519 (X-Wing)
	kdfID  = 0x0001 // HKDF-SHA256
	aeadID = 0x0002 // AES-256-GCM

	hdrLen   = 7
	encLen   = 1120 // X-Wing encapsulation
	nonceLen = 12
	keyLen   = 32

	requestLabel  = "message/bhttp request"
	responseLabel = "message/bhttp response"
)

// ErrMalformed covers anything that doesn't decrypt and parse.
var ErrMalformed = errors.New("tunnel: malformed message")

// Key is relayd's tunnel key pair.
type Key struct{ priv hpke.PrivateKey }

// LoadOrCreateKey reads the private key at path, creating it (0600) if absent.
// The app builds in the public half, so the file must never be replaced.
func LoadOrCreateKey(path string) (*Key, error) {
	kem := hpke.MLKEM768X25519()
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		priv, err := kem.GenerateKey()
		if err != nil {
			return nil, err
		}
		if raw, err = priv.Bytes(); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return nil, err
		}
		if _, err := f.Write(raw); err != nil {
			f.Close()
			return nil, err
		}
		if err := f.Close(); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	priv, err := kem.NewPrivateKey(raw)
	if err != nil {
		return nil, fmt.Errorf("tunnel key %s: %w", path, err)
	}
	return &Key{priv: priv}, nil
}

// PublicKey is the encapsulation key the app builds in.
func (k *Key) PublicKey() []byte { return k.priv.PublicKey().Bytes() }

func header() []byte {
	h := make([]byte, hdrLen)
	h[0] = KeyID
	binary.BigEndian.PutUint16(h[1:], kemID)
	binary.BigEndian.PutUint16(h[3:], kdfID)
	binary.BigEndian.PutUint16(h[5:], aeadID)
	return h
}

func info(label string, hdr []byte) []byte {
	return append(append([]byte(label), 0), hdr...)
}

// Opened is a decrypted request and what's needed to answer it.
type Opened struct {
	Request   *Request
	enc       []byte
	recipient *hpke.Recipient
}

// Open decrypts an encapsulated request.
func (k *Key) Open(msg []byte) (*Opened, error) {
	hdr := header()
	if len(msg) < hdrLen+encLen || string(msg[:hdrLen]) != string(hdr) {
		return nil, ErrMalformed
	}
	enc := msg[hdrLen : hdrLen+encLen]
	r, err := hpke.NewRecipient(enc, k.priv, hpke.HKDFSHA256(), hpke.AES256GCM(), info(requestLabel, hdr))
	if err != nil {
		return nil, ErrMalformed
	}
	plain, err := r.Open(nil, msg[hdrLen+encLen:])
	if err != nil {
		return nil, ErrMalformed
	}
	req, err := DecodeRequest(plain)
	if err != nil {
		return nil, err
	}
	return &Opened{Request: req, enc: enc, recipient: r}, nil
}

// Seal encrypts the response (RFC 9458 section 4.4), padded.
func (o *Opened) Seal(resp *Response) ([]byte, error) {
	secret, err := o.recipient.Export(responseLabel, keyLen)
	if err != nil {
		return nil, err
	}
	responseNonce := make([]byte, keyLen)
	if _, err := rand.Read(responseNonce); err != nil {
		return nil, err
	}
	salt := append(append([]byte{}, o.enc...), responseNonce...)
	prk, err := hkdf.Extract(sha256.New, secret, salt)
	if err != nil {
		return nil, err
	}
	aead, nonce, err := responseAEAD(prk)
	if err != nil {
		return nil, err
	}
	return append(responseNonce, aead.Seal(nil, nonce, Pad(resp.Encode()), nil)...), nil
}

// Stream returns the frame ciphers for a WebSocket opened by this request.
func (o *Opened) Stream() (*Stream, error) {
	c2s, err := o.recipient.Export("relay tunnel ws c2s", keyLen)
	if err != nil {
		return nil, err
	}
	s2c, err := o.recipient.Export("relay tunnel ws s2c", keyLen)
	if err != nil {
		return nil, err
	}
	in, err := newGCM(c2s)
	if err != nil {
		return nil, err
	}
	out, err := newGCM(s2c)
	if err != nil {
		return nil, err
	}
	return &Stream{in: in, out: out}, nil
}

// PaddedLen is the padding bucket for n bytes of plaintext: powers of two
// from 256 bytes to 64 KiB, then whole multiples of 64 KiB.
func PaddedLen(n int) int {
	for b := 256; b <= 64<<10; b <<= 1 {
		if n <= b {
			return b
		}
	}
	return (n + 64<<10 - 1) / (64 << 10) * (64 << 10)
}

// Pad appends zeros up to the next bucket (Binary HTTP allows trailing zero
// padding after a known-length message).
func Pad(b []byte) []byte {
	return append(b, make([]byte, PaddedLen(len(b))-len(b))...)
}
