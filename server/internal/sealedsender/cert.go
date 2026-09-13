package sealedsender

import (
	"crypto/rand"
	"errors"

	"filippo.io/edwards25519"
	"golang.org/x/crypto/curve25519"
	"google.golang.org/protobuf/encoding/protowire"
)

// djbType is libsignal's public-key type byte prepended to a 32-byte Curve25519
// public key to form the 33-byte serialized form.
const djbType = 0x05

// KeyPair is a Curve25519 keypair in libsignal's serialization: a clamped
// 32-byte private scalar and a 33-byte (0x05 || X25519) public key.
type KeyPair struct {
	Private []byte // 32 bytes, clamped
	Public  []byte // 33 bytes, 0x05 || montgomery public
}

// GenerateKeyPair creates a clamped Curve25519 keypair suitable for signing
// sealed-sender certificates (trust root or server certificate key).
func GenerateKeyPair() (KeyPair, error) {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return KeyPair{}, err
	}
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return KeyPair{}, err
	}
	return KeyPair{Private: priv, Public: append([]byte{djbType}, pub...)}, nil
}

// edwardsPublic derives the Edwards public point (A = a·B) for a clamped private
// scalar, used only by the internal self-test verifier.
func edwardsPublic(privClamped []byte) (*edwards25519.Point, error) {
	a, err := edwards25519.NewScalar().SetUniformBytes(pad64(privClamped))
	if err != nil {
		return nil, err
	}
	return new(edwards25519.Point).ScalarBaseMult(a), nil
}

// MintServerCertificate builds a serialized signal.proto.sealed_sender
// ServerCertificate: the inner {id, key} certificate signed by the trust root.
func MintServerCertificate(trustRootPrivate []byte, keyID uint32, serverPublic []byte) ([]byte, error) {
	if len(serverPublic) != 33 {
		return nil, errors.New("sealedsender: server public key must be 33 bytes")
	}
	var cert []byte
	cert = protowire.AppendTag(cert, 1, protowire.VarintType)
	cert = protowire.AppendVarint(cert, uint64(keyID))
	cert = protowire.AppendTag(cert, 2, protowire.BytesType)
	cert = protowire.AppendBytes(cert, serverPublic)

	sig, err := signXEd25519(trustRootPrivate, cert)
	if err != nil {
		return nil, err
	}
	return wrapCertificate(cert, sig), nil
}

// MintSenderCertificate builds a serialized SenderCertificate binding
// (senderUUID, deviceID, identityKey) with an expiry, signed by the server
// certificate key. serverCertificate is the serialized ServerCertificate from
// MintServerCertificate; identityKey is the sender's 33-byte identity public key.
func MintSenderCertificate(
	serverCertificate, serverCertPrivate []byte,
	senderUUID string, deviceID uint32, identityKey []byte, expiresMs uint64,
) ([]byte, error) {
	if len(identityKey) != 33 {
		return nil, errors.New("sealedsender: identity key must be 33 bytes")
	}
	if senderUUID == "" {
		return nil, errors.New("sealedsender: sender uuid required")
	}
	// SenderCertificate.Certificate fields, ascending: device(2), expires(3,
	// fixed64), identityKey(4), signer certificate(5), uuidString(6). e164 (1)
	// omitted. Field order is free — libsignal verifies over these exact bytes.
	var cert []byte
	cert = protowire.AppendTag(cert, 2, protowire.VarintType)
	cert = protowire.AppendVarint(cert, uint64(deviceID))
	cert = protowire.AppendTag(cert, 3, protowire.Fixed64Type)
	cert = protowire.AppendFixed64(cert, expiresMs)
	cert = protowire.AppendTag(cert, 4, protowire.BytesType)
	cert = protowire.AppendBytes(cert, identityKey)
	cert = protowire.AppendTag(cert, 5, protowire.BytesType)
	cert = protowire.AppendBytes(cert, serverCertificate)
	cert = protowire.AppendTag(cert, 6, protowire.BytesType)
	cert = protowire.AppendString(cert, senderUUID)

	sig, err := signXEd25519(serverCertPrivate, cert)
	if err != nil {
		return nil, err
	}
	return wrapCertificate(cert, sig), nil
}

// wrapCertificate serializes the outer {certificate, signature} envelope shared
// by ServerCertificate and SenderCertificate.
func wrapCertificate(certificate, signature []byte) []byte {
	var out []byte
	out = protowire.AppendTag(out, 1, protowire.BytesType)
	out = protowire.AppendBytes(out, certificate)
	out = protowire.AppendTag(out, 2, protowire.BytesType)
	out = protowire.AppendBytes(out, signature)
	return out
}
