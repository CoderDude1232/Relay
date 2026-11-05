package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Identity is a verified sign-in identity (an Apple or Google account) beyond
// the email address, which links by its token. Link is "apple:<hex>" or
// "google:<hex>", a keyed hash of the provider's subject (api.identityLink);
// "" for an email code. SupabaseID is the Supabase auth user an older app
// signed in through, kept only so deleting the account deletes that user too.
type Identity struct {
	Link       string
	SupabaseID string
}

// findByIdentityTx picks the account an identity signs in to: by link, then
// by legacy Supabase id, then by verified email token. byEmail reports the
// last, which the caller back-fills the links on.
func findByIdentityTx(ctx context.Context, tx pgx.Tx, pick, suffix string, id Identity, emailToken []byte, dest ...any) (byEmail bool, err error) {
	err = pgx.ErrNoRows
	if id.Link != "" {
		err = tx.QueryRow(ctx, pick+`WHERE identity_link = $1`+suffix, id.Link).Scan(dest...)
	}
	if errors.Is(err, pgx.ErrNoRows) && id.SupabaseID != "" {
		err = tx.QueryRow(ctx, pick+`WHERE supabase_user_id = $1`+suffix, id.SupabaseID).Scan(dest...)
	}
	if errors.Is(err, pgx.ErrNoRows) && len(emailToken) > 0 {
		err = tx.QueryRow(ctx, pick+`WHERE email_token = $1`+suffix, emailToken).Scan(dest...)
		byEmail = err == nil
	}
	return byEmail, err
}

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// linkIdentityTx back-fills an account's empty links; an existing link to
// another identity is never overwritten.
func linkIdentityTx(ctx context.Context, q execer, accountID string, id Identity) error {
	if id.Link != "" {
		if _, err := q.Exec(ctx,
			`UPDATE accounts SET identity_link = $1 WHERE id = $2 AND identity_link IS NULL`, id.Link, accountID); err != nil {
			return err
		}
	}
	if id.SupabaseID != "" {
		if _, err := q.Exec(ctx,
			`UPDATE accounts SET supabase_user_id = $1 WHERE id = $2 AND (supabase_user_id IS NULL OR supabase_user_id = '')`,
			id.SupabaseID, accountID); err != nil {
			return err
		}
	}
	return nil
}

// LinkIdentityIfUnlinked back-fills an account's empty links (a sign-in that
// adopted the account by its verified email, after its second step).
func (s *Store) LinkIdentityIfUnlinked(accountID string, id Identity) error {
	return linkIdentityTx(context.Background(), s.db, accountID, id)
}

// SetIdentityLink records a migrated account's link (cmd relayd
// -migrate-supabase); an existing one is kept.
func (s *Store) SetIdentityLink(accountID, link string) error {
	return linkIdentityTx(context.Background(), s.db, accountID, Identity{Link: link})
}

// SupabaseLinkedAccounts lists accounts still linked to a Supabase user, for
// the one-off migration.
func (s *Store) SupabaseLinkedAccounts() (map[string]string, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT id, supabase_user_id FROM accounts WHERE COALESCE(supabase_user_id, '') <> ''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, sup string
		if err := rows.Scan(&id, &sup); err != nil {
			return nil, err
		}
		out[id] = sup
	}
	return out, rows.Err()
}

// SetAccountEmailTokenIfEmpty records a verified email's token on an account
// that has none (the Supabase migration); false if it already had one or
// another account uses the address.
func (s *Store) SetAccountEmailTokenIfEmpty(accountID string, token []byte) (bool, error) {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET email_token = $1 WHERE id = $2 AND email_token IS NULL
		   AND NOT EXISTS (SELECT 1 FROM accounts WHERE email_token = $1)`, token, accountID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}
