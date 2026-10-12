package store

import "context"

// Supabase auth users whose relay account was deleted are queued in
// pending_supabase_deletions (by DeleteAccount) until the admin API confirms
// the delete, so a Supabase outage can't leave the user's email behind.

// PendingSupabaseDeletions returns up to limit queued Supabase user ids, in
// random order so one id that keeps failing can't hold up the rest. Ids that
// are linked to an account again (the user signed up anew before the delete
// went through) are dropped first: that user is in use.
func (s *Store) PendingSupabaseDeletions(limit int) ([]string, error) {
	ctx := context.Background()
	if _, err := s.db.Exec(ctx, `
		DELETE FROM pending_supabase_deletions p
		USING accounts a WHERE a.supabase_user_id = p.user_id`); err != nil {
		return nil, err
	}
	rows, err := s.db.Query(ctx,
		`SELECT user_id FROM pending_supabase_deletions ORDER BY random() LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// SupabaseUserLinked reports whether an account is linked to the Supabase user.
func (s *Store) SupabaseUserLinked(userID string) (bool, error) {
	var linked bool
	err := s.db.QueryRow(context.Background(),
		`SELECT EXISTS (SELECT 1 FROM accounts WHERE supabase_user_id = $1)`, userID).Scan(&linked)
	return linked, err
}

// ClearPendingSupabaseDeletion removes a queued id once its delete succeeded.
func (s *Store) ClearPendingSupabaseDeletion(userID string) error {
	_, err := s.db.Exec(context.Background(),
		`DELETE FROM pending_supabase_deletions WHERE user_id = $1`, userID)
	return err
}
