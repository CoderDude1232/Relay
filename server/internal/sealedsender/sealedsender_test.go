package sealedsender

import (
	"bytes"
	"encoding/base64"
	"os"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
)

// TestPrintInteropVector mints a certificate chain and prints it as base64 for
// embedding into the libsignal (Swift) interop test, which is the authoritative
// proof that Go-minted certs validate natively. Run with:
//   PRINT_INTEROP_VECTOR=1 go test ./internal/sealedsender/ -run TestPrintInteropVector -v
func TestPrintInteropVector(t *testing.T) {
	if os.Getenv("PRINT_INTEROP_VECTOR") == "" {
		t.Skip("set PRINT_INTEROP_VECTOR=1 to emit an interop vector")
	}
	trustRoot, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	serverKey, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	serverCert, err := MintServerCertificate(trustRoot.Private, 1, serverKey.Public)
	if err != nil {
		t.Fatal(err)
	}
	identityKey := append([]byte{djbType}, bytes.Repeat([]byte{0x42}, 32)...)
	const uuid = "11111111-1111-1111-1111-111111111111"
	const expiresMs = 4102444800000 // 2100-01-01, far future
	senderCert, err := MintSenderCertificate(serverCert, serverKey.Private, uuid, 1, identityKey, expiresMs)
	if err != nil {
		t.Fatal(err)
	}
	enc := base64.StdEncoding.EncodeToString
	t.Logf("INTEROP_TRUST_ROOT_PUB=%s", enc(trustRoot.Public))
	t.Logf("INTEROP_SENDER_CERT=%s", enc(senderCert))
	t.Logf("INTEROP_IDENTITY_KEY=%s", enc(identityKey))
	t.Logf("INTEROP_UUID=%s", uuid)
	t.Logf("INTEROP_EXPIRES_MS=%d", int64(expiresMs))
}

// parseWrapper extracts the inner certificate bytes (field 1) and signature
// (field 2) from a serialized Server/SenderCertificate envelope.
func parseWrapper(t *testing.T, data []byte) (cert, sig []byte) {
	t.Helper()
	b := data
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			t.Fatalf("bad tag")
		}
		b = b[n:]
		if typ != protowire.BytesType {
			t.Fatalf("unexpected wire type %v for field %d", typ, num)
		}
		v, n := protowire.ConsumeBytes(b)
		if n < 0 {
			t.Fatalf("bad bytes for field %d", num)
		}
		b = b[n:]
		switch num {
		case 1:
			cert = append([]byte(nil), v...)
		case 2:
			sig = append([]byte(nil), v...)
		}
	}
	if cert == nil || sig == nil {
		t.Fatalf("missing certificate or signature")
	}
	return cert, sig
}

func TestXEd25519SignVerifyRoundTrip(t *testing.T) {
	kp, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("relay sealed-sender test message")
	sig, err := signXEd25519(kp.Private, msg)
	if err != nil {
		t.Fatal(err)
	}
	edPub, err := edwardsPublic(kp.Private)
	if err != nil {
		t.Fatal(err)
	}
	if !verifyXEd25519(edPub, msg, sig) {
		t.Fatal("valid signature did not verify")
	}
	// Tamper: flipping a message byte must fail.
	if verifyXEd25519(edPub, append(msg, '!'), sig) {
		t.Fatal("verification accepted a tampered message")
	}
	// Tamper: flipping a signature byte must fail.
	bad := append([]byte(nil), sig...)
	bad[0] ^= 0x01
	if verifyXEd25519(edPub, msg, bad) {
		t.Fatal("verification accepted a tampered signature")
	}
}

func TestMintCertificatesVerify(t *testing.T) {
	trustRoot, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	serverKey, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}

	serverCert, err := MintServerCertificate(trustRoot.Private, 1, serverKey.Public)
	if err != nil {
		t.Fatal(err)
	}
	innerServer, serverSig := parseWrapper(t, serverCert)
	trustEd, err := edwardsPublic(trustRoot.Private)
	if err != nil {
		t.Fatal(err)
	}
	if !verifyXEd25519(trustEd, innerServer, serverSig) {
		t.Fatal("server certificate signature did not verify against trust root")
	}

	// A stand-in 33-byte identity key (0x05 || 32 bytes).
	identityKey := append([]byte{djbType}, bytes.Repeat([]byte{0x42}, 32)...)
	senderCert, err := MintSenderCertificate(
		serverCert, serverKey.Private,
		"11111111-1111-1111-1111-111111111111", 1, identityKey, 1_800_000_000_000,
	)
	if err != nil {
		t.Fatal(err)
	}
	innerSender, senderSig := parseWrapper(t, senderCert)
	serverEd, err := edwardsPublic(serverKey.Private)
	if err != nil {
		t.Fatal(err)
	}
	if !verifyXEd25519(serverEd, innerSender, senderSig) {
		t.Fatal("sender certificate signature did not verify against server key")
	}

	// The sender certificate must embed the exact server certificate bytes so the
	// client can validate the chain.
	if !bytes.Contains(senderCert, serverCert) {
		t.Fatal("sender certificate does not embed the server certificate")
	}
}
