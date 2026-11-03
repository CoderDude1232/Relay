package store

import (
	"context"
	"encoding/binary"

	"github.com/relayapp/relay-server/internal/kt"
)

// Key transparency storage: every published version of every account's
// identity keys, and every signed head. Rows are only ever added.

// KTCurrentKeys is every account's identity keys right now, from its devices.
func (s *Store) KTCurrentKeys() (map[string][][]byte, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT DISTINCT account_id, identity_key FROM devices WHERE identity_key IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][][]byte{}
	for rows.Next() {
		var account string
		var key []byte
		if err := rows.Scan(&account, &key); err != nil {
			return nil, err
		}
		out[account] = append(out[account], key)
	}
	return out, rows.Err()
}

// KTLoad returns every stored history (oldest version first) and head (oldest first).
func (s *Store) KTLoad() (map[string][]kt.Version, []kt.Head, error) {
	ctx := context.Background()
	rows, err := s.db.Query(ctx,
		`SELECT account_id, version, commitment, nonce, keys, chain, epoch FROM kt_versions ORDER BY account_id, version`)
	if err != nil {
		return nil, nil, err
	}
	histories := map[string][]kt.Version{}
	for rows.Next() {
		var account string
		var version int32
		var commitment, nonce, keys, chain []byte
		var epoch int64
		if err := rows.Scan(&account, &version, &commitment, &nonce, &keys, &chain, &epoch); err != nil {
			rows.Close()
			return nil, nil, err
		}
		v := kt.Version{Version: uint32(version), Keys: decodeKTKeys(keys), Epoch: uint64(epoch)}
		copy(v.Commitment[:], commitment)
		copy(v.Nonce[:], nonce)
		copy(v.Chain[:], chain)
		histories[account] = append(histories[account], v)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	hrows, err := s.db.Query(ctx, `SELECT epoch, smt_root, log_size, log_root, time, sig FROM kt_heads ORDER BY epoch`)
	if err != nil {
		return nil, nil, err
	}
	defer hrows.Close()
	var heads []kt.Head
	for hrows.Next() {
		var h kt.Head
		var epoch, logSize, t int64
		var smtRoot, logRoot []byte
		if err := hrows.Scan(&epoch, &smtRoot, &logSize, &logRoot, &t, &h.Sig); err != nil {
			return nil, nil, err
		}
		h.Epoch, h.LogSize, h.Time = uint64(epoch), uint64(logSize), uint64(t)
		copy(h.SMTRoot[:], smtRoot)
		copy(h.LogRoot[:], logRoot)
		heads = append(heads, h)
	}
	return histories, heads, hrows.Err()
}

// KTSaveEpoch stores a newly published head and the versions it published,
// together, before the head is served.
func (s *Store) KTSaveEpoch(head kt.Head, published map[string][]kt.Version) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for account, versions := range published {
		for _, v := range versions {
			if _, err := tx.Exec(ctx,
				`INSERT INTO kt_versions (account_id, version, commitment, nonce, keys, chain, epoch)
				 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
				account, int32(v.Version), v.Commitment[:], v.Nonce[:], encodeKTKeys(v.Keys), v.Chain[:], int64(v.Epoch)); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO kt_heads (epoch, smt_root, log_size, log_root, time, sig) VALUES ($1, $2, $3, $4, $5, $6)`,
		int64(head.Epoch), head.SMTRoot[:], int64(head.LogSize), head.LogRoot[:], int64(head.Time), head.Sig); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Keys as 2-byte length + bytes, concatenated.
func encodeKTKeys(keys [][]byte) []byte {
	var out []byte
	for _, k := range keys {
		var n [2]byte
		binary.BigEndian.PutUint16(n[:], uint16(len(k)))
		out = append(append(out, n[:]...), k...)
	}
	if out == nil {
		out = []byte{}
	}
	return out
}

func decodeKTKeys(b []byte) [][]byte {
	var keys [][]byte
	for len(b) >= 2 {
		n := int(binary.BigEndian.Uint16(b))
		if len(b) < 2+n {
			break
		}
		keys = append(keys, append([]byte(nil), b[2:2+n]...))
		b = b[2+n:]
	}
	return keys
}
