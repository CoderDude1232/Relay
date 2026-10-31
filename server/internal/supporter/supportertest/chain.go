// Package supportertest signs App Store-shaped transactions with a throwaway
// certificate chain, for tests.
package supportertest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"testing"
	"time"
)

// Chain is a root, intermediate and leaf like Apple's receipt signing chain.
type Chain struct {
	Root, Inter, Leaf *x509.Certificate
	leafKey           *ecdsa.PrivateKey
}

// NewChain makes a chain; markers adds Apple's marker extensions.
func NewChain(t testing.TB, markers bool) *Chain {
	t.Helper()
	mk := func(tmpl, parent *x509.Certificate, pub, signer any) *x509.Certificate {
		der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, pub, signer)
		if err != nil {
			t.Fatal(err)
		}
		c, _ := x509.ParseCertificate(der)
		return c
	}
	key := func() *ecdsa.PrivateKey { k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader); return k }
	marker := func(oid asn1.ObjectIdentifier) []pkix.Extension {
		if !markers {
			return nil
		}
		return []pkix.Extension{{Id: oid, Value: []byte{5, 0}}}
	}
	notBefore, notAfter := time.Now().Add(-time.Hour), time.Now().Add(24*time.Hour)
	rk, ik, lk := key(), key(), key()
	rootT := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "root"},
		NotBefore: notBefore, NotAfter: notAfter, IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign}
	root := mk(rootT, rootT, &rk.PublicKey, rk)
	interT := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "inter"},
		NotBefore: notBefore, NotAfter: notAfter, IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign, ExtraExtensions: marker(asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1})}
	inter := mk(interT, root, &ik.PublicKey, rk)
	leafT := &x509.Certificate{SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "leaf"},
		NotBefore: notBefore, NotAfter: notAfter, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtraExtensions: marker(asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1})}
	leaf := mk(leafT, inter, &lk.PublicKey, ik)
	return &Chain{Root: root, Inter: inter, Leaf: leaf, leafKey: lk}
}

// Sign returns payload as a transaction JWS.
func (c *Chain) Sign(t testing.TB, payload map[string]any) string {
	t.Helper()
	x5c := []string{}
	for _, cert := range []*x509.Certificate{c.Leaf, c.Inter, c.Root} {
		x5c = append(x5c, base64.StdEncoding.EncodeToString(cert.Raw))
	}
	h, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": x5c})
	p, _ := json.Marshal(payload)
	signing := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(p)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.leafKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// Payload is a valid monthly subscription transaction as of now.
func Payload(now time.Time, transactionID string) map[string]any {
	return map[string]any{
		"transactionId": transactionID, "bundleId": "app.relaymsg",
		"productId": "app.relaymsg.supporter.monthly1", "type": "Auto-Renewable Subscription",
		"environment": "Production", "purchaseDate": now.Add(-time.Minute).UnixMilli(),
		"expiresDate": now.AddDate(0, 1, 0).UnixMilli(), "signedDate": now.UnixMilli(),
	}
}
