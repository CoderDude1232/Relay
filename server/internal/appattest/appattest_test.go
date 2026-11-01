package appattest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"errors"
	"math/big"
	"testing"
	"time"

	"github.com/fxamacker/cbor/v2"
)

const testAppID = "TEAMID1234.app.relaymsg"

// fakeDevice plays the device and Apple's attestation CA.
type fakeDevice struct {
	root    *x509.Certificate
	caKey   *ecdsa.PrivateKey
	key     *ecdsa.PrivateKey
	keyID   []byte
	counter uint32
}

func newFakeDevice(t *testing.T) *fakeDevice {
	t.Helper()
	caKey, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test App Attestation Root CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	root, _ := x509.ParseCertificate(der)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	point, _ := key.PublicKey.Bytes()
	id := sha256.Sum256(point)
	return &fakeDevice{root: root, caKey: caKey, key: key, keyID: id[:]}
}

func authDataBytes(appID string, counter uint32, aaguid, credID []byte) []byte {
	h := sha256.Sum256([]byte(appID))
	b := append([]byte{}, h[:]...)
	b = append(b, 0x40)
	b = binary.BigEndian.AppendUint32(b, counter)
	if aaguid != nil {
		b = append(b, aaguid...)
		b = binary.BigEndian.AppendUint16(b, uint16(len(credID)))
		b = append(b, credID...)
	}
	return b
}

func (d *fakeDevice) attest(t *testing.T, appID string, aaguid, clientDataHash []byte) []byte {
	t.Helper()
	auth := authDataBytes(appID, 0, aaguid, d.keyID)
	nonce := sha256.Sum256(append(append([]byte{}, auth...), clientDataHash...))
	ext, _ := asn1.Marshal(struct {
		Nonce []byte `asn1:"explicit,tag:1"`
	}{nonce[:]})
	// A one-level chain: the root signs an intermediate, which signs the leaf.
	interKey, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	interTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "Test Intermediate"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	interDER, _ := x509.CreateCertificate(rand.Reader, interTmpl, d.root, &interKey.PublicKey, d.caKey)
	inter, _ := x509.ParseCertificate(interDER)
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "leaf"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		ExtraExtensions: []pkix.Extension{{Id: nonceOID, Value: ext}},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, inter, &d.key.PublicKey, interKey)
	if err != nil {
		t.Fatal(err)
	}
	obj := map[string]any{
		"fmt":      "apple-appattest",
		"attStmt":  map[string]any{"x5c": [][]byte{leafDER, interDER}, "receipt": []byte("r")},
		"authData": auth,
	}
	out, _ := cbor.Marshal(obj)
	return out
}

func (d *fakeDevice) assert(t *testing.T, appID string, clientDataHash []byte) []byte {
	t.Helper()
	d.counter++
	auth := authDataBytes(appID, d.counter, nil, nil)
	nonce := sha256.Sum256(append(append([]byte{}, auth...), clientDataHash...))
	digest := sha256.Sum256(nonce[:])
	sig, _ := ecdsa.SignASN1(rand.Reader, d.key, digest[:])
	out, _ := cbor.Marshal(map[string]any{"signature": sig, "authenticatorData": auth})
	return out
}

func TestAttestAndAssert(t *testing.T) {
	v, err := NewVerifier(testAppID, false)
	if err != nil {
		t.Fatal(err)
	}
	d := newFakeDevice(t)
	v.TrustRoot(d.root)
	cdh := sha256.Sum256([]byte("challenge"))
	now := time.Now()

	pub, err := v.VerifyAttestation(d.keyID, d.attest(t, testAppID, aaguidProduction, cdh[:]), cdh[:], now)
	if err != nil {
		t.Fatal(err)
	}

	// Wrong client data, another app, a development key, a key id mismatch.
	other := sha256.Sum256([]byte("other"))
	if _, err := v.VerifyAttestation(d.keyID, d.attest(t, testAppID, aaguidProduction, cdh[:]), other[:], now); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted another challenge")
	}
	if _, err := v.VerifyAttestation(d.keyID, d.attest(t, "OTHER.app", aaguidProduction, cdh[:]), cdh[:], now); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted another app")
	}
	if _, err := v.VerifyAttestation(d.keyID, d.attest(t, testAppID, aaguidDevelopment, cdh[:]), cdh[:], now); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted a development key")
	}
	if _, err := v.VerifyAttestation(other[:], d.attest(t, testAppID, aaguidProduction, cdh[:]), cdh[:], now); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted a mismatched key id")
	}
	// Not signed by the trusted root.
	stranger := newFakeDevice(t)
	stranger.key, stranger.keyID = d.key, d.keyID
	if _, err := v.VerifyAttestation(d.keyID, stranger.attest(t, testAppID, aaguidProduction, cdh[:]), cdh[:], now); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted an untrusted chain")
	}

	dev, _ := NewVerifier(testAppID, true)
	dev.TrustRoot(d.root)
	if _, err := dev.VerifyAttestation(d.keyID, d.attest(t, testAppID, aaguidDevelopment, cdh[:]), cdh[:], now); err != nil {
		t.Fatalf("development key: %v", err)
	}

	// Assertions: counter must rise, data must match.
	req := sha256.Sum256([]byte("request"))
	a := d.assert(t, testAppID, req[:])
	counter, err := v.VerifyAssertion(pub, a, req[:], 0)
	if err != nil || counter != 1 {
		t.Fatalf("assertion: %v %d", err, counter)
	}
	if _, err := v.VerifyAssertion(pub, a, req[:], counter); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted a replayed assertion")
	}
	if _, err := v.VerifyAssertion(pub, d.assert(t, testAppID, req[:]), other[:], counter); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted an assertion over other data")
	}
	if _, err := v.VerifyAssertion(pub, d.assert(t, "OTHER.app", req[:]), req[:], counter); !errors.Is(err, ErrInvalid) {
		t.Fatal("accepted an assertion for another app")
	}
}

func TestAppleRootParses(t *testing.T) {
	root, err := x509.ParseCertificate(appleRootDER)
	if err != nil || root.Subject.CommonName != "Apple App Attestation Root CA" {
		t.Fatalf("root: %v %v", err, root)
	}
}
