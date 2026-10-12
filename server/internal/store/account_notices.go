package store

import (
	"context"
	"time"
)

// Account notice kinds (relaypb.AccountNotice.kind).
const (
	NoticePasskeyAdded        = "passkey_added"
	NoticePasskeyRemoved      = "passkey_removed"
	NoticeRecoveryKeySet      = "recovery_key_set"
	NoticeRecoveryKeyRemoved  = "recovery_key_removed"
	NoticeAccountPasswordSet  = "account_password_set"
	NoticeEmailRemoved        = "email_removed"
	NoticeEmailChanged        = "email_changed"
	accountNoticeRetentionDay = 30
)

// AccountNotice is a pending notice for one device.
type AccountNotice struct {
	Kind   string
	TimeMs int64
}

// AddAccountNotice records a notice for every device of the account except
// the one that made the change. Rows go when delivered (TakeAccountNotices),
// when the device is removed, or after 30 days.
func (s *Store) AddAccountNotice(accountID string, exceptDeviceID uint32, kind string) error {
	_, err := s.db.Exec(context.Background(),
		`INSERT INTO account_notices (account_id, device_id, kind, created_at)
		 SELECT account_id, device_id, $3, $4 FROM devices WHERE account_id = $1 AND device_id <> $2`,
		accountID, int64(exceptDeviceID), kind, time.Now().UnixMilli())
	return err
}

// TakeAccountNotices removes and returns a device's pending notices, oldest
// first. Each is returned to exactly one caller.
func (s *Store) TakeAccountNotices(accountID string, deviceID uint32) ([]AccountNotice, error) {
	rows, err := s.db.Query(context.Background(),
		`DELETE FROM account_notices WHERE account_id = $1 AND device_id = $2 RETURNING kind, created_at`,
		accountID, int64(deviceID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AccountNotice
	for rows.Next() {
		var n AccountNotice
		if err := rows.Scan(&n.Kind, &n.TimeMs); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// RETURNING has no ORDER BY; sort here (a device rarely has more than a few).
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].TimeMs < out[j-1].TimeMs; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out, nil
}

// RestoreAccountNotice puts back a notice that couldn't be delivered.
func (s *Store) RestoreAccountNotice(accountID string, deviceID uint32, n AccountNotice) error {
	_, err := s.db.Exec(context.Background(),
		`INSERT INTO account_notices (account_id, device_id, kind, created_at)
		 SELECT $1, $2, $3, $4 WHERE EXISTS (SELECT 1 FROM devices WHERE account_id = $1 AND device_id = $2)`,
		accountID, int64(deviceID), n.Kind, n.TimeMs)
	return err
}
