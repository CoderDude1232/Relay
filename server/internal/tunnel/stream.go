package tunnel

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func responseAEAD(prk []byte) (cipher.AEAD, []byte, error) {
	key, err := hkdf.Expand(sha256.New, prk, "key", keyLen)
	if err != nil {
		return nil, nil, err
	}
	nonce, err := hkdf.Expand(sha256.New, prk, "nonce", nonceLen)
	if err != nil {
		return nil, nil, err
	}
	aead, err := newGCM(key)
	return aead, nonce, err
}

// Stream encrypts WebSocket frames once the opening request is accepted. Each
// direction has its own key and a 96-bit big-endian counter nonce starting at
// zero, so frames can't be dropped, reordered or replayed unnoticed. The
// plaintext is a 4-byte length, the frame, then zeros to the padding bucket.
// Seal and Open are each for one goroutine at a time.
type Stream struct {
	in, out       cipher.AEAD
	inSeq, outSeq uint64
}

// ErrFrame: a frame that doesn't decrypt or parse; the connection must close.
var ErrFrame = errors.New("tunnel: bad frame")

func seqNonce(seq uint64) []byte {
	n := make([]byte, nonceLen)
	binary.BigEndian.PutUint64(n[4:], seq)
	return n
}

func sealFrame(aead cipher.AEAD, seq uint64, frame []byte) []byte {
	plain := binary.BigEndian.AppendUint32(make([]byte, 0, 4+len(frame)), uint32(len(frame)))
	return aead.Seal(nil, seqNonce(seq), Pad(append(plain, frame...)), nil)
}

func openFrame(aead cipher.AEAD, seq uint64, msg []byte) ([]byte, error) {
	plain, err := aead.Open(nil, seqNonce(seq), msg, nil)
	if err != nil || len(plain) < 4 {
		return nil, ErrFrame
	}
	n := binary.BigEndian.Uint32(plain)
	if uint64(n) > uint64(len(plain)-4) {
		return nil, ErrFrame
	}
	return plain[4 : 4+n], nil
}

// Seal encrypts one outgoing (server-to-client) frame.
func (s *Stream) Seal(frame []byte) []byte {
	out := sealFrame(s.out, s.outSeq, frame)
	s.outSeq++
	return out
}

// Open decrypts the next incoming (client-to-server) frame.
func (s *Stream) Open(msg []byte) ([]byte, error) {
	frame, err := openFrame(s.in, s.inSeq, msg)
	if err != nil {
		return nil, err
	}
	s.inSeq++
	return frame, nil
}

// Client is the app's side, for tests and tools.
type Client struct {
	pub hpke.PublicKey
}

// NewClient builds a client for an encapsulation key.
func NewClient(publicKey []byte) (*Client, error) {
	pub, err := hpke.MLKEM768X25519().NewPublicKey(publicKey)
	if err != nil {
		return nil, err
	}
	return &Client{pub: pub}, nil
}

// Pending is a sent request awaiting its response.
type Pending struct {
	enc    []byte
	sender *hpke.Sender
}

// Seal encapsulates req.
func (c *Client) Seal(req *Request) ([]byte, *Pending, error) {
	hdr := header()
	enc, sender, err := hpke.NewSender(c.pub, hpke.HKDFSHA256(), hpke.AES256GCM(), info(requestLabel, hdr))
	if err != nil {
		return nil, nil, err
	}
	ct, err := sender.Seal(nil, Pad(req.Encode()))
	if err != nil {
		return nil, nil, err
	}
	return append(append(hdr, enc...), ct...), &Pending{enc: enc, sender: sender}, nil
}

// Open decrypts the response to the request.
func (p *Pending) Open(msg []byte) (*Response, error) {
	if len(msg) < keyLen {
		return nil, ErrMalformed
	}
	secret, err := p.sender.Export(responseLabel, keyLen)
	if err != nil {
		return nil, err
	}
	salt := append(append([]byte{}, p.enc...), msg[:keyLen]...)
	prk, err := hkdf.Extract(sha256.New, secret, salt)
	if err != nil {
		return nil, err
	}
	aead, nonce, err := responseAEAD(prk)
	if err != nil {
		return nil, err
	}
	plain, err := aead.Open(nil, nonce, msg[keyLen:], nil)
	if err != nil {
		return nil, ErrMalformed
	}
	return DecodeResponse(plain)
}

// ClientStream is the app's frame ciphers (the mirror of Stream).
type ClientStream struct{ Stream }

// Stream returns the client's frame ciphers.
func (p *Pending) Stream() (*ClientStream, error) {
	c2s, err := p.sender.Export("relay tunnel ws c2s", keyLen)
	if err != nil {
		return nil, err
	}
	s2c, err := p.sender.Export("relay tunnel ws s2c", keyLen)
	if err != nil {
		return nil, err
	}
	out, err := newGCM(c2s)
	if err != nil {
		return nil, err
	}
	in, err := newGCM(s2c)
	if err != nil {
		return nil, err
	}
	return &ClientStream{Stream{in: in, out: out}}, nil
}
