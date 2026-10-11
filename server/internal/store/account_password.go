package store

import (
	"bytes"
	"errors"

	"golang.org/x/crypto/bcrypt"
)

// AccountPassword is what a client presents for the account password.
//
// Current clients never send the password itself: they send Key, a value
// derived from it on the device (Argon2id with its own salt). The chat-list
// blob's password slot is keyed by a different derivation of the same
// password, so what the relay receives can't open it. Legacy is the raw
// password, sent by older clients, or once by a current client to upgrade an
// account whose hash predates keys (ErrAccountPasswordUpgradeRequired).
type AccountPassword struct {
	Key    string
	Legacy string
}

// LegacyPassword wraps a raw password (older clients).
func LegacyPassword(raw string) AccountPassword { return AccountPassword{Legacy: raw} }

// Empty reports whether nothing was presented.
func (p AccountPassword) Empty() bool { return p.Key == "" && p.Legacy == "" }

// keyedHashPrefix marks a stored hash of a derived key; a bare bcrypt hash
// ("$2a$...") is of a raw password.
var keyedHashPrefix = []byte("k2$")

func keyedSecret(key string) []byte { return []byte("k2:" + key) }

// hash is what to store for a newly set password: the key when the client
// sent one, else (older clients) the raw password.
func (p AccountPassword) hash() ([]byte, error) {
	if p.Key != "" {
		h, err := bcrypt.GenerateFromPassword(keyedSecret(p.Key), bcrypt.DefaultCost)
		if err != nil {
			return nil, err
		}
		return append(append([]byte{}, keyedHashPrefix...), h...), nil
	}
	if p.Legacy != "" {
		return bcrypt.GenerateFromPassword([]byte(p.Legacy), bcrypt.DefaultCost)
	}
	return nil, nil
}

// ErrAccountPasswordUpgradeRequired: the account's stored hash is of a raw
// password and only a key was presented. The client retries once with both,
// and the hash is replaced by one of the key.
var ErrAccountPasswordUpgradeRequired = errors.New("store: account password needs a one-time upgrade")

// verify checks p against a stored hash (always one bcrypt). upgraded, when
// non-nil, is the hash to store instead (a raw-password account presenting
// its password plus a key).
func (p AccountPassword) verify(stored []byte) (ok bool, upgraded []byte, err error) {
	if bytes.HasPrefix(stored, keyedHashPrefix) {
		if p.Key == "" {
			burnRecoveryBcrypt(p.Legacy)
			return false, nil, nil
		}
		return bcrypt.CompareHashAndPassword(stored[len(keyedHashPrefix):], keyedSecret(p.Key)) == nil, nil, nil
	}
	if p.Legacy == "" {
		return false, nil, ErrAccountPasswordUpgradeRequired
	}
	if bcrypt.CompareHashAndPassword(stored, []byte(p.Legacy)) != nil {
		return false, nil, nil
	}
	if p.Key != "" {
		upgraded, err = AccountPassword{Key: p.Key}.hash()
		if err != nil {
			return false, nil, err
		}
	}
	return true, upgraded, nil
}

// burn spends one bcrypt so a missing account costs the same as a wrong
// password.
func (p AccountPassword) burn() {
	if p.Key != "" {
		burnRecoveryBcrypt("k2:" + p.Key)
	} else {
		burnRecoveryBcrypt(p.Legacy)
	}
}
