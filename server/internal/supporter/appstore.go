package supporter

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

// App Store transactions arrive as the JWS StoreKit 2 hands the app
// (VerificationResult.jwsRepresentation): ES256 over header.payload, with the
// signing chain in the header's x5c. We check the chain up to Apple Root CA -
// G3 (embedded) and Apple's marker extensions, then the signature, the same as
// Apple's App Store Server Library does offline.

// Apple Root CA - G3, DER, from https://www.apple.com/certificateauthority/
// (SHA-256 63343ABF…653E9179).
//
//go:embed AppleRootCA-G3.cer
var appleRootDER []byte

var (
	// Marker extensions on Apple's App Store receipt signing certificates.
	oidLeafMarker         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidIntermediateMarker = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// ProductIDs are the Relay Supporter subscriptions (one group, three levels).
var ProductIDs = []string{
	"app.relaymsg.supporter.monthly1",
	"app.relaymsg.supporter.monthly2",
	"app.relaymsg.supporter.monthly3",
}

// ErrBadTransaction is any transaction that doesn't verify or doesn't qualify.
var ErrBadTransaction = errors.New("supporter: transaction rejected")

// Transaction is the part of a signed App Store transaction the relay uses.
type Transaction struct {
	TransactionID  string `json:"transactionId"`
	BundleID       string `json:"bundleId"`
	ProductID      string `json:"productId"`
	Type           string `json:"type"`
	Environment    string `json:"environment"`
	PurchaseDate   int64  `json:"purchaseDate"`
	ExpiresDate    int64  `json:"expiresDate"`
	SignedDate     int64  `json:"signedDate"`
	RevocationDate int64  `json:"revocationDate"`
}

// Sandbox: TestFlight and development purchases (free, renewing every few
// minutes).
func (t *Transaction) Sandbox() bool { return t.Environment == "Sandbox" }

// Expires is when the paid period ends.
func (t *Transaction) Expires() time.Time { return time.UnixMilli(t.ExpiresDate) }

// AppStoreVerifier checks signed transactions for one app.
type AppStoreVerifier struct {
	BundleID     string
	ProductIDs   map[string]bool
	AllowSandbox bool
	roots        *x509.CertPool
}

func NewAppStoreVerifier(bundleID string, productIDs []string, allowSandbox bool) (*AppStoreVerifier, error) {
	root, err := x509.ParseCertificate(appleRootDER)
	if err != nil {
		return nil, fmt.Errorf("supporter: parse Apple root: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(root)
	ids := map[string]bool{}
	for _, id := range productIDs {
		ids[id] = true
	}
	return &AppStoreVerifier{BundleID: bundleID, ProductIDs: ids, AllowSandbox: allowSandbox, roots: pool}, nil
}

// TrustRoot replaces Apple's root, for tests.
func (v *AppStoreVerifier) TrustRoot(root *x509.Certificate) {
	v.roots = x509.NewCertPool()
	v.roots.AddCert(root)
}

// Verify checks a transaction JWS and that it's a current, unrevoked
// subscription to one of our products.
func (v *AppStoreVerifier) Verify(jws string, now time.Time) (*Transaction, error) {
	tx, err := v.verifySignature(jws)
	if err != nil {
		return nil, err
	}
	switch {
	case tx.BundleID != v.BundleID:
		return nil, fmt.Errorf("%w: bundle", ErrBadTransaction)
	case !v.ProductIDs[tx.ProductID]:
		return nil, fmt.Errorf("%w: product", ErrBadTransaction)
	case tx.Type != "Auto-Renewable Subscription":
		return nil, fmt.Errorf("%w: type", ErrBadTransaction)
	case tx.Environment != "Production" && !(tx.Sandbox() && v.AllowSandbox):
		return nil, fmt.Errorf("%w: environment %q", ErrBadTransaction, tx.Environment)
	case tx.RevocationDate != 0:
		return nil, fmt.Errorf("%w: revoked", ErrBadTransaction)
	case tx.TransactionID == "" || !tx.Expires().After(now):
		return nil, fmt.Errorf("%w: expired", ErrBadTransaction)
	}
	return tx, nil
}

func (v *AppStoreVerifier) verifySignature(jws string) (*Transaction, error) {
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("%w: not a JWS", ErrBadTransaction)
	}
	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("%w: header", ErrBadTransaction)
	}
	var header struct {
		Alg string   `json:"alg"`
		X5C []string `json:"x5c"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil || header.Alg != "ES256" || len(header.X5C) != 3 {
		return nil, fmt.Errorf("%w: header", ErrBadTransaction)
	}
	var certs []*x509.Certificate
	for _, enc := range header.X5C {
		der, err := base64.StdEncoding.DecodeString(enc)
		if err != nil {
			return nil, fmt.Errorf("%w: x5c", ErrBadTransaction)
		}
		c, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, fmt.Errorf("%w: x5c", ErrBadTransaction)
		}
		certs = append(certs, c)
	}
	leaf, intermediate := certs[0], certs[1]
	if !hasExtension(leaf, oidLeafMarker) || !hasExtension(intermediate, oidIntermediateMarker) {
		return nil, fmt.Errorf("%w: not an App Store certificate", ErrBadTransaction)
	}

	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("%w: payload", ErrBadTransaction)
	}
	var tx Transaction
	if err := json.Unmarshal(payloadJSON, &tx); err != nil {
		return nil, fmt.Errorf("%w: payload", ErrBadTransaction)
	}

	// The chain is checked as of the signing time, as Apple's library does
	// offline; the third x5c entry is ignored in favour of the embedded root.
	inter := x509.NewCertPool()
	inter.AddCert(intermediate)
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         v.roots,
		Intermediates: inter,
		CurrentTime:   time.UnixMilli(tx.SignedDate),
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return nil, fmt.Errorf("%w: chain: %v", ErrBadTransaction, err)
	}

	key, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("%w: key", ErrBadTransaction)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return nil, fmt.Errorf("%w: signature", ErrBadTransaction)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(key, digest[:], r, s) {
		return nil, fmt.Errorf("%w: signature", ErrBadTransaction)
	}
	return &tx, nil
}

func hasExtension(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}
