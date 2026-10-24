package api

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"hash"
	"hash/maphash"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/limitkey"
	"github.com/relayapp/relay-server/internal/store"
)

// Signature-based request authentication (Relay-Sig v2). Instead of presenting
// a reusable device password (HTTP Basic), a client signs each request with
// its P-256 auth key, the same keypair used for nuke commands, whose private
// half never leaves the device. The server verifies against the stored
// auth_public_key, so nothing replayable crosses the wire.
//
// Wire format:
//
//	Authorization:         Relay-Sig <accountId>.<deviceId>:<base64(ECDSA-P256 sig)>
//	X-Relay-Timestamp:     <unix millis>
//	X-Relay-Nonce:         <base64 of 16-64 random bytes>
//	X-Relay-Content-SHA256 (optional): <lowercase hex SHA-256 of the body>
//
// The signature is ECDSA-P256 (ASN.1 DER) over SHA-256 of the canonical string
// (fields joined by "\n"):
//
//	"relay-sig-v2"
//	METHOD
//	REQUEST-URI   (escaped path + "?" + raw query when present, e.g. /v1/keys/abc?device=2)
//	ACCOUNT-ID
//	DEVICE-ID     (canonical decimal, no leading zeros)
//	TIMESTAMP
//	NONCE         (exactly as sent in X-Relay-Nonce)
//	BODY-SHA256   (lowercase hex SHA-256 of the request body; of "" when empty)
//
// The server always buffers the body (bounded by the 1 MiB request cap) and
// hashes it itself; a declared X-Relay-Content-SHA256, if sent, must match.
// Only a streamable route (the attachment upload, see streamableBodyRoute) may
// instead be checked against the declared digest as it is read. Everywhere
// else a JSON handler may stop reading before EOF, so a streamed body whose
// tail differs from what was signed would never be detected.
//
// A request is accepted iff the signature validates, the timestamp is within
// sigAuthSkew of now, and the (account, device, nonce) triple hasn't been seen in
// that window.
const sigAuthScheme = "Relay-Sig"

// sigAuthVersion is the domain/version tag that opens the canonical string.
const sigAuthVersion = "relay-sig-v2"

// bodyHashHeader carries an optional client-declared body digest.
const bodyHashHeader = "X-Relay-Content-SHA256"

const sigAuthSkew = 5 * time.Minute

const (
	minNonceBytes = 16
	maxNonceBytes = 64
)

// emptyBodySHA256 is hex(SHA-256("")).
var emptyBodySHA256 = hex.EncodeToString(sha256.New().Sum(nil))

// Replay cache. Seen nonces are kept in maps bucketed by expiry time: an entry
// expires at its signed timestamp + sigAuthSkew, and lands in the slot
// expiry/nonceSlotWidth. Expired slots are dropped whole (no per-entry scan),
// and at most about 3 slots are ever live (expiries span now to now+2*skew). The
// cache is sharded by device so unrelated devices don't contend on one lock,
// and each device may hold at most maxNoncesPerSlot entries per slot, so one
// (validly signing) device can't grow the cache without bound.
//
// Entries are keyed with limitkey.Hash (salted, rotated daily) rather than raw
// account/device ids. A replay is checked under both the current and the
// previous salt, so a salt rotation can't make a just-stored nonce
// unrecognisable.
const (
	nonceSlotWidth   = sigAuthSkew
	maxNoncesPerSlot = 20000 // per device per 5-min slot (~66 signed requests/s)
	nonceShards      = 16
)

var (
	errReplayedNonce = errors.New("replayed nonce")
	errNonceBudget   = errors.New("too many signed requests from this device; slow down")
	// errSignedBeforeStart: a valid signature made before this process
	// started. The replay cache lives in memory, so a request captured just
	// before a restart could otherwise be replayed once just after it.
	errSignedBeforeStart = errors.New("request signed before the relay restarted; sign it again")
)

// signedSinceMs is when this process started (unix ms). Signatures with an
// earlier timestamp are refused: the replay cache can't vouch for them. A
// client whose clock runs slow sees this only until its clock passes the
// start time, and gets 425 (retry), never 401.
var signedSinceMs = time.Now().UnixMilli()

type nonceSlot struct {
	nonces    map[string]struct{} // hashed (account, device, nonce)
	perDevice map[string]int      // entries in this slot, by hashed (account, device)
}

type nonceShard struct {
	mu    sync.Mutex
	slots map[int64]*nonceSlot // by expiry slot index
}

type nonceCache struct {
	seed   maphash.Seed // picks a shard; never stored
	shards [nonceShards]nonceShard
}

func newNonceCache() *nonceCache {
	c := &nonceCache{seed: maphash.MakeSeed()}
	for i := range c.shards {
		c.shards[i].slots = make(map[int64]*nonceSlot)
	}
	return c
}

// checkAndStore records (accountID, deviceID, nonce) until expiryMs. It
// returns errReplayedNonce if the triple is already recorded and unexpired, or
// errNonceBudget if the device has exhausted its per-slot entry budget.
func (c *nonceCache) checkAndStore(accountID string, deviceID uint32, nonce []byte, nowMs, expiryMs int64) error {
	dev := strconv.FormatUint(uint64(deviceID), 10)
	devKey, _ := limitkey.HashCurrentAndPrevious("sig-nonce-device", accountID, dev)
	cur, prev := limitkey.HashCurrentAndPrevious("sig-nonce", accountID, dev, string(nonce))

	sh := &c.shards[maphash.String(c.seed, accountID+"."+dev)%nonceShards]
	sh.mu.Lock()
	defer sh.mu.Unlock()
	for idx, slot := range sh.slots {
		if (idx+1)*nonceSlotWidth.Milliseconds() <= nowMs {
			delete(sh.slots, idx) // every entry in it has expired
			continue
		}
		if _, ok := slot.nonces[cur]; ok {
			return errReplayedNonce
		}
		if _, ok := slot.nonces[prev]; ok && prev != "" {
			return errReplayedNonce
		}
	}
	idx := expiryMs / nonceSlotWidth.Milliseconds()
	slot := sh.slots[idx]
	if slot == nil {
		slot = &nonceSlot{nonces: make(map[string]struct{}), perDevice: make(map[string]int)}
		sh.slots[idx] = slot
	}
	if slot.perDevice[devKey] >= maxNoncesPerSlot {
		return errNonceBudget
	}
	slot.nonces[cur] = struct{}{}
	slot.perDevice[devKey]++
	return nil
}

var requestNonces = newNonceCache()

// parseCredential splits "<accountID>.<deviceID>" and insists the device id is
// in canonical decimal form, so "1", "01" and "+1" can't name the same device
// under different strings (which would also defeat nonce-cache keying).
func parseCredential(cred string) (accountID string, deviceID uint32, err error) {
	accountID, devStr, ok := strings.Cut(cred, ".")
	if !ok || accountID == "" {
		return "", 0, errors.New("credential must be <accountID>.<deviceID>")
	}
	devID, err := strconv.ParseUint(devStr, 10, 32)
	if err != nil || strconv.FormatUint(devID, 10) != devStr {
		return "", 0, errors.New("bad device id")
	}
	return accountID, uint32(devID), nil
}

// sigAuthHeaders is a parsed (not yet verified) Relay-Sig request.
type sigAuthHeaders struct {
	accountID string
	deviceID  uint32
	sig       []byte
	timestamp string
	tsMs      int64
	nonce     string // as sent (signed verbatim)
	nonceRaw  []byte // decoded, used for replay keying
}

func parseSigAuthHeaders(r *http.Request, now time.Time) (*sigAuthHeaders, error) {
	raw := strings.TrimPrefix(r.Header.Get("Authorization"), sigAuthScheme+" ")
	credPart, sigB64, ok := strings.Cut(raw, ":")
	if !ok {
		return nil, errors.New("malformed signature authorization")
	}
	accountID, deviceID, err := parseCredential(credPart)
	if err != nil {
		return nil, err
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil || len(sig) == 0 {
		return nil, errors.New("bad signature encoding")
	}
	tsStr := r.Header.Get("X-Relay-Timestamp")
	nonce := r.Header.Get("X-Relay-Nonce")
	if tsStr == "" || nonce == "" {
		return nil, errors.New("missing timestamp or nonce")
	}
	tsMs, err := strconv.ParseInt(tsStr, 10, 64)
	if err != nil || strconv.FormatInt(tsMs, 10) != tsStr {
		return nil, errors.New("bad timestamp")
	}
	if diff := now.UnixMilli() - tsMs; diff > sigAuthSkew.Milliseconds() || diff < -sigAuthSkew.Milliseconds() {
		return nil, errors.New("timestamp outside allowed window")
	}
	nonceRaw, err := base64.StdEncoding.DecodeString(nonce)
	if err != nil || len(nonceRaw) < minNonceBytes || len(nonceRaw) > maxNonceBytes {
		return nil, errors.New("nonce must be base64 of 16–64 bytes")
	}
	return &sigAuthHeaders{
		accountID: accountID, deviceID: deviceID, sig: sig,
		timestamp: tsStr, tsMs: tsMs, nonce: nonce, nonceRaw: nonceRaw,
	}, nil
}

var errBodyHashMismatch = errors.New("request body does not match the signed digest")

// streamableBodyRoute reports whether r may have its body verified while it
// streams instead of being buffered first: only the attachment upload
// (PUT /v1/attachments/{id}), whose handler copies the body to EOF and
// discards the blob when the read fails. That route is unauthenticated, so in
// practice every signed request is buffered.
func streamableBodyRoute(r *http.Request) bool {
	return r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/v1/attachments/")
}

// requestBodyDigest returns the hex SHA-256 the signature must cover. The body
// is buffered (limitRequestBody caps it at 1 MiB, so an oversized body fails
// here), hashed by the server and rewound for the handler; a declared digest,
// if any, must then match. Only on a streamable route, for a large or
// unknown-length body with a declared digest, is the declared value used and
// r.Body wrapped so the read fails at EOF on mismatch.
func requestBodyDigest(r *http.Request) (string, error) {
	declared := strings.ToLower(r.Header.Get(bodyHashHeader))
	if declared != "" {
		if b, err := hex.DecodeString(declared); err != nil || len(b) != sha256.Size {
			return "", errors.New("bad declared body digest")
		}
	}
	if r.Body == nil || r.Body == http.NoBody {
		if declared != "" && declared != emptyBodySHA256 {
			return "", errBodyHashMismatch
		}
		return emptyBodySHA256, nil
	}
	if declared != "" && streamableBodyRoute(r) && (r.ContentLength < 0 || r.ContentLength > defaultMaxRequestBodySize) {
		r.Body = &digestVerifyingBody{rc: r.Body, h: sha256.New(), want: declared}
		return declared, nil
	}
	buf, err := io.ReadAll(r.Body)
	if err != nil {
		return "", err
	}
	r.Body.Close()
	r.Body = io.NopCloser(bytes.NewReader(buf))
	sum := sha256.Sum256(buf)
	actual := hex.EncodeToString(sum[:])
	if declared != "" && subtle.ConstantTimeCompare([]byte(declared), []byte(actual)) != 1 {
		return "", errBodyHashMismatch
	}
	return actual, nil
}

// digestVerifyingBody hashes a streamed body and turns EOF into an error when
// the digest doesn't match what the client signed.
type digestVerifyingBody struct {
	rc   io.ReadCloser
	h    hash.Hash
	want string
}

func (d *digestVerifyingBody) Read(p []byte) (int, error) {
	n, err := d.rc.Read(p)
	d.h.Write(p[:n])
	if errors.Is(err, io.EOF) {
		if hex.EncodeToString(d.h.Sum(nil)) != d.want {
			return n, errBodyHashMismatch
		}
	}
	return n, err
}

func (d *digestVerifyingBody) Close() error { return d.rc.Close() }

// verifySigAuth checks an ECDSA-P256 (ASN.1) signature over SHA-256(canonical)
// against an uncompressed P-256 public key.
func verifySigAuth(publicKey []byte, canonical string, sig []byte) error {
	if len(publicKey) == 0 {
		return errors.New("device has no authorization key")
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), publicKey)
	if x == nil || y == nil {
		return errors.New("invalid device authorization key")
	}
	pub := ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	digest := sha256.Sum256([]byte(canonical))
	if !ecdsa.VerifyASN1(&pub, digest[:], sig) {
		return errors.New("signature verification failed")
	}
	return nil
}

// authenticateSignature validates a Relay-Sig request and returns the device.
func (s *Server) authenticateSignature(r *http.Request) (*store.Device, error) {
	now := time.Now()
	h, err := parseSigAuthHeaders(r, now)
	if err != nil {
		return nil, err
	}
	dev, err := s.store.DeviceByID(h.accountID, h.deviceID)
	if err != nil {
		return nil, err
	}
	if len(dev.AuthPublicKey) == 0 {
		return nil, errors.New("device has no authorization key")
	}
	bodyDigest, err := requestBodyDigest(r)
	if err != nil {
		return nil, err
	}
	canonical := sigAuthCanonical(r.Method, r.URL.RequestURI(), h.accountID, h.deviceID, h.timestamp, h.nonce, bodyDigest)
	if err := verifySigAuth(dev.AuthPublicKey, canonical, h.sig); err != nil {
		return nil, err
	}
	if h.tsMs < signedSinceMs {
		return nil, errSignedBeforeStart
	}
	// Key replay protection on the parsed identity + decoded nonce so encoding
	// variants of the same values can't slip past the cache.
	if err := requestNonces.checkAndStore(h.accountID, h.deviceID, h.nonceRaw, now.UnixMilli(), h.tsMs+sigAuthSkew.Milliseconds()); err != nil {
		return nil, err
	}
	return dev, nil
}

// sigAuthCanonical builds the exact string the client signs. Clients must
// reproduce it byte for byte.
func sigAuthCanonical(method, requestURI, accountID string, deviceID uint32, timestamp, nonce, bodySHA256Hex string) string {
	return strings.Join([]string{
		sigAuthVersion,
		method,
		requestURI,
		accountID,
		strconv.FormatUint(uint64(deviceID), 10),
		timestamp,
		nonce,
		bodySHA256Hex,
	}, "\n")
}
