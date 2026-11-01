// Package appattest verifies Apple App Attest attestations and assertions,
// so an unauthenticated endpoint (sending an SMS code) can require a genuine
// copy of the app on a real Apple device. See Apple's "Validating apps that
// connect to your server".
package appattest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"github.com/fxamacker/cbor/v2"
)

// AppleAppAttestationRootCA.cer is Apple's App Attestation Root CA (DER),
// from https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem,
// SHA-256 1cb9823b…6242c932.
//
//go:embed AppleAppAttestationRootCA.cer
var appleRootDER []byte

var (
	nonceOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}

	aaguidProduction  = append([]byte("appattest"), make([]byte, 7)...)
	aaguidDevelopment = []byte("appattestdevelop")

	ErrInvalid = errors.New("appattest: invalid")
)

// Verifier checks attestations for one app.
type Verifier struct {
	appIDHash        [32]byte // SHA-256 of "<team id>.<bundle id>"
	allowDevelopment bool
	roots            *x509.CertPool
}

// NewVerifier is for appID "<team id>.<bundle id>". allowDevelopment accepts
// keys from development builds (Xcode installs) as well as App Store and
// TestFlight builds.
func NewVerifier(appID string, allowDevelopment bool) (*Verifier, error) {
	root, err := x509.ParseCertificate(appleRootDER)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	pool.AddCert(root)
	return &Verifier{appIDHash: sha256.Sum256([]byte(appID)), allowDevelopment: allowDevelopment, roots: pool}, nil
}

// TrustRoot replaces Apple's root (tests only).
func (v *Verifier) TrustRoot(root *x509.Certificate) {
	v.roots = x509.NewCertPool()
	v.roots.AddCert(root)
}

type attestationObject struct {
	Fmt     string `cbor:"fmt"`
	AttStmt struct {
		X5C     [][]byte `cbor:"x5c"`
		Receipt []byte   `cbor:"receipt"`
	} `cbor:"attStmt"`
	AuthData []byte `cbor:"authData"`
}

type authData struct {
	rpIDHash []byte
	counter  uint32
	aaguid   []byte
	credID   []byte
}

func parseAuthData(b []byte, attested bool) (authData, error) {
	if len(b) < 37 {
		return authData{}, ErrInvalid
	}
	a := authData{rpIDHash: b[:32], counter: binary.BigEndian.Uint32(b[33:37])}
	if !attested {
		return a, nil
	}
	rest := b[37:]
	if len(rest) < 18 {
		return authData{}, ErrInvalid
	}
	a.aaguid = rest[:16]
	n := int(binary.BigEndian.Uint16(rest[16:18]))
	if len(rest) < 18+n {
		return authData{}, ErrInvalid
	}
	a.credID = rest[18 : 18+n]
	return a, nil
}

// VerifyAttestation checks a new key's attestation (from
// DCAppAttestService.attestKey with clientDataHash) and returns the key's
// public key (uncompressed P-256 point) to store for later assertions.
func (v *Verifier) VerifyAttestation(keyID, attestation, clientDataHash []byte, now time.Time) ([]byte, error) {
	var obj attestationObject
	if err := cbor.Unmarshal(attestation, &obj); err != nil || obj.Fmt != "apple-appattest" || len(obj.AttStmt.X5C) < 2 {
		return nil, ErrInvalid
	}
	leaf, err := x509.ParseCertificate(obj.AttStmt.X5C[0])
	if err != nil {
		return nil, ErrInvalid
	}
	intermediates := x509.NewCertPool()
	for _, der := range obj.AttStmt.X5C[1:] {
		c, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, ErrInvalid
		}
		intermediates.AddCert(c)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots: v.roots, Intermediates: intermediates, CurrentTime: now,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return nil, fmt.Errorf("%w: chain: %v", ErrInvalid, err)
	}

	// The leaf certifies nonce = SHA-256(authData || clientDataHash).
	nonce := sha256.Sum256(append(append([]byte{}, obj.AuthData...), clientDataHash...))
	var certified []byte
	for _, ext := range leaf.Extensions {
		if ext.Id.Equal(nonceOID) {
			var seq struct {
				Nonce []byte `asn1:"explicit,tag:1"`
			}
			if _, err := asn1.Unmarshal(ext.Value, &seq); err != nil {
				return nil, ErrInvalid
			}
			certified = seq.Nonce
		}
	}
	if !bytes.Equal(certified, nonce[:]) {
		return nil, fmt.Errorf("%w: nonce", ErrInvalid)
	}

	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, ErrInvalid
	}
	point, err := pub.Bytes()
	if err != nil {
		return nil, ErrInvalid
	}
	if id := sha256.Sum256(point); !bytes.Equal(id[:], keyID) {
		return nil, fmt.Errorf("%w: key id", ErrInvalid)
	}

	a, err := parseAuthData(obj.AuthData, true)
	if err != nil || !bytes.Equal(a.rpIDHash, v.appIDHash[:]) || a.counter != 0 || !bytes.Equal(a.credID, keyID) {
		return nil, fmt.Errorf("%w: auth data", ErrInvalid)
	}
	switch {
	case bytes.Equal(a.aaguid, aaguidProduction):
	case v.allowDevelopment && bytes.Equal(a.aaguid, aaguidDevelopment):
	default:
		return nil, fmt.Errorf("%w: environment", ErrInvalid)
	}
	return point, nil
}

type assertionObject struct {
	Signature         []byte `cbor:"signature"`
	AuthenticatorData []byte `cbor:"authenticatorData"`
}

// VerifyAssertion checks an assertion (DCAppAttestService.generateAssertion
// with clientDataHash) by the key with publicKey, whose last seen counter was
// previous. It returns the new counter, which the caller must store.
func (v *Verifier) VerifyAssertion(publicKey, assertion, clientDataHash []byte, previous uint32) (uint32, error) {
	var obj assertionObject
	if err := cbor.Unmarshal(assertion, &obj); err != nil {
		return 0, ErrInvalid
	}
	pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), publicKey)
	if err != nil {
		return 0, ErrInvalid
	}
	nonce := sha256.Sum256(append(append([]byte{}, obj.AuthenticatorData...), clientDataHash...))
	digest := sha256.Sum256(nonce[:])
	if !ecdsa.VerifyASN1(pub, digest[:], obj.Signature) {
		return 0, fmt.Errorf("%w: signature", ErrInvalid)
	}
	a, err := parseAuthData(obj.AuthenticatorData, false)
	if err != nil || !bytes.Equal(a.rpIDHash, v.appIDHash[:]) {
		return 0, fmt.Errorf("%w: auth data", ErrInvalid)
	}
	if a.counter <= previous {
		return 0, fmt.Errorf("%w: counter", ErrInvalid)
	}
	return a.counter, nil
}
