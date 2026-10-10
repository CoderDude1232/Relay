package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

// Demo accounts (accounts.is_demo) are review/test accounts, set by an
// operator with SQL. They live in their own island: they only see and reach
// other demo accounts, their credentials are locked, and deleting one resets it
// instead (see the API's demo checks).

// ErrDemoAccount is returned by mutations a demo account isn't allowed.
var ErrDemoAccount = errors.New("store: demo account")

// IsDemoAccount reports whether accountID is a demo account (false if unknown).
func (s *Store) IsDemoAccount(accountID string) (bool, error) {
	var demo bool
	err := s.db.QueryRow(context.Background(),
		`SELECT is_demo FROM accounts WHERE id = $1`, accountID).Scan(&demo)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return demo, err
}

// DirectoryBucketsFor is DirectoryBuckets restricted to demo accounts (demo =
// true) or to everyone else (demo = false).
func (s *Store) DirectoryBucketsFor(buckets []uint16, demo bool) ([]BucketEntry, error) {
	if len(buckets) == 0 {
		return nil, nil
	}
	ids := make([]int32, len(buckets))
	for i, b := range buckets {
		ids[i] = int32(b)
	}
	rows, err := s.db.Query(context.Background(),
		`SELECT d.bucket, d.tag, d.box, d.access_box FROM directory d JOIN accounts a ON a.id = d.account_id
         WHERE d.bucket = ANY($1) AND d.tag IS NOT NULL AND d.box IS NOT NULL AND a.is_demo = $2`, ids, demo)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BucketEntry
	for rows.Next() {
		var e BucketEntry
		var b int32
		if err := rows.Scan(&b, &e.Tag, &e.Box, &e.AccessBox); err != nil {
			return nil, err
		}
		e.Bucket = uint16(b)
		out = append(out, e)
	}
	return out, rows.Err()
}

// ResetDemoAccount is what "delete account" does for a demo account: it drops
// every device (keys, queues) like a fresh sign-in would, but keeps the account
// and its login, so the same credentials work again. Returns the removed device
// ids.
func (s *Store) ResetDemoAccount(accountID string) ([]uint32, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var demo bool
	if err := tx.QueryRow(ctx, `SELECT is_demo FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&demo); errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if !demo {
		return nil, errors.New("store: not a demo account")
	}
	removed, err := replaceDevicesTx(ctx, tx, accountID)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = device_list_version + 1 WHERE id = $1`, accountID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM account_storage WHERE account_id = $1`, accountID); err != nil {
		return nil, err
	}
	return removed, tx.Commit(ctx)
}

// SetDemoAccount marks or unmarks a demo account (operator use and tests).
func (s *Store) SetDemoAccount(accountID string, demo bool) error {
	tag, err := s.db.Exec(context.Background(), `UPDATE accounts SET is_demo = $2 WHERE id = $1`, accountID, demo)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// DemoSignIn provisions a fresh device on a demo account (replacing its
// devices, like any sign-in), for the review-code sign-in. It prefers a demo
// account with no device signed in, so a second reviewer device gets the
// other demo account instead of signing the first one out.
func (s *Store) DemoSignIn() (dev AddedDevice, devicePassword string, err error) {
	ctx := context.Background()
	err = s.db.QueryRow(ctx, `
        SELECT a.id, a.username FROM accounts a WHERE a.is_demo
        ORDER BY (SELECT count(*) FROM devices d WHERE d.account_id = a.id), a.username
        LIMIT 1`).Scan(&dev.AccountID, &dev.Username)
	if errors.Is(err, pgx.ErrNoRows) {
		return AddedDevice{}, "", ErrNotFound
	}
	if err != nil {
		return AddedDevice{}, "", err
	}
	var raw [32]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return AddedDevice{}, "", err
	}
	devicePassword = hex.EncodeToString(raw[:])
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, "", err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, "", err
	}
	defer tx.Rollback(ctx)
	if dev.ReplacedDevices, err = replaceDevicesTx(ctx, tx, dev.AccountID); err != nil {
		return AddedDevice{}, "", err
	}
	if dev.DeviceID, dev.MailboxID, dev.DeviceListVersion, err = addDeviceTx(ctx, tx, dev.AccountID, deviceHash); err != nil {
		return AddedDevice{}, "", err
	}
	return dev, devicePassword, tx.Commit(ctx)
}

// DemoPeers returns the usernames of the other demo accounts.
func (s *Store) DemoPeers(accountID string) ([]string, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT username FROM accounts WHERE is_demo AND id <> $1 ORDER BY username`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}
