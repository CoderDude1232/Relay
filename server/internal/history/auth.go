package history

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"
)

// AuthHeader carries relayd's MAC on every historyd request:
//
//	Relay-History-Auth: <unix seconds>.<hex HMAC-SHA256(secret, METHOD "\n" PATH "\n" UNIX "\n" hex SHA-256(body))>
const AuthHeader = "Relay-History-Auth"

// AuthSkew is how far a request's timestamp may be from historyd's clock.
const AuthSkew = 5 * time.Minute

// minSecretBytes keeps a typo'd or truncated secret file from being accepted.
const minSecretBytes = 32

func authMAC(secret []byte, method, path string, unix int64, body []byte) []byte {
	sum := sha256.Sum256(body)
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(method + "\n" + path + "\n" + strconv.FormatInt(unix, 10) + "\n" + hex.EncodeToString(sum[:])))
	return m.Sum(nil)
}

// SignRequest returns the AuthHeader value for a request at time now.
func SignRequest(secret []byte, method, path string, body []byte, now time.Time) string {
	unix := now.Unix()
	return strconv.FormatInt(unix, 10) + "." + hex.EncodeToString(authMAC(secret, method, path, unix, body))
}

var errAuth = errors.New("history: bad or stale request signature")

// VerifyRequest checks an AuthHeader value.
func VerifyRequest(secret []byte, header, method, path string, body []byte, now time.Time) error {
	ts, macHex, ok := strings.Cut(header, ".")
	if !ok {
		return errAuth
	}
	unix, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return errAuth
	}
	if d := now.Sub(time.Unix(unix, 0)); d > AuthSkew || d < -AuthSkew {
		return errAuth
	}
	got, err := hex.DecodeString(macHex)
	if err != nil {
		return errAuth
	}
	if subtle.ConstantTimeCompare(got, authMAC(secret, method, path, unix, body)) != 1 {
		return errAuth
	}
	return nil
}

// LoadSecret reads the shared relayd/historyd secret (surrounding whitespace
// ignored), e.g. one made with `openssl rand -hex 32`.
func LoadSecret(path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	secret := []byte(strings.TrimSpace(string(raw)))
	if len(secret) < minSecretBytes {
		return nil, errors.New("history: secret file holds fewer than 32 bytes")
	}
	return secret, nil
}
