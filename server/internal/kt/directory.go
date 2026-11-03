package kt

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"sort"
	"sync"
	"time"
)

// Version is one state of an account's keys.
type Version struct {
	Version    uint32
	Commitment [32]byte
	Nonce      [32]byte
	Keys       [][]byte
	Chain      [32]byte
	Epoch      uint64 // the epoch that first published it; 0 while pending
}

// Directory holds every account's key history and the published epochs.
// Changes made with SetKeys appear in lookups only after Publish.
type Directory struct {
	vrfKey  *rsa.PrivateKey
	signKey ed25519.PrivateKey

	mu        sync.RWMutex
	accounts  map[string][]Version
	labels    map[string][32]byte
	vrfProofs map[string][]byte
	smt       *SMT
	logLeaves [][32]byte
	heads     []Head
	dirty     bool
}

func NewDirectory(vrfKey *rsa.PrivateKey, signKey ed25519.PrivateKey) *Directory {
	return &Directory{
		vrfKey: vrfKey, signKey: signKey,
		accounts: map[string][]Version{}, labels: map[string][32]byte{}, vrfProofs: map[string][]byte{},
		smt: NewSMT(),
	}
}

func (d *Directory) label(account string) ([32]byte, []byte) {
	if l, ok := d.labels[account]; ok {
		return l, d.vrfProofs[account]
	}
	pi := VRFProve(d.vrfKey, []byte(account))
	l := VRFHash(pi)
	d.labels[account], d.vrfProofs[account] = l, pi
	return l, pi
}

func sameKeys(a, b [][]byte) bool {
	if len(a) != len(b) {
		return false
	}
	sa, sb := sortedKeys(a), sortedKeys(b)
	for i := range sa {
		if !bytes.Equal(sa[i], sb[i]) {
			return false
		}
	}
	return true
}

func sortedKeys(keys [][]byte) [][]byte {
	out := make([][]byte, len(keys))
	copy(out, keys)
	sort.Slice(out, func(i, j int) bool { return bytes.Compare(out[i], out[j]) < 0 })
	return out
}

// SetKeys records the account's current identity keys (none once it's
// deleted). Returns true if that's a new version.
func (d *Directory) SetKeys(account string, keys [][]byte) (bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	history := d.accounts[account]
	if n := len(history); n > 0 && sameKeys(history[n-1].Keys, keys) {
		return false, nil
	}
	if len(history) == 0 && len(keys) == 0 {
		return false, nil
	}
	var nonce [32]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return false, err
	}
	var prev [32]byte
	if n := len(history); n > 0 {
		prev = history[n-1].Chain
	}
	v := uint32(len(history) + 1)
	commitment := Commit(nonce, keys)
	d.accounts[account] = append(history, Version{
		Version: v, Commitment: commitment, Nonce: nonce, Keys: sortedKeys(keys),
		Chain: Chain(prev, v, commitment),
	})
	d.dirty = true
	return true, nil
}

// Restore loads a stored history (newest last), as published before.
func (d *Directory) Restore(account string, versions []Version) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.accounts[account] = versions
	if n := len(versions); n > 0 && versions[n-1].Epoch != 0 {
		label, _ := d.label(account)
		d.smt.Set(label, versions[n-1].Chain)
	}
	d.dirty = d.dirty || (len(versions) > 0 && versions[len(versions)-1].Epoch == 0)
}

// RestoreLog loads the published heads and log leaves, oldest first.
func (d *Directory) RestoreLog(heads []Head) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.heads = heads
	d.logLeaves = d.logLeaves[:0]
	for _, h := range heads {
		d.logLeaves = append(d.logLeaves, logLeafHash(LogEntry(h.Epoch, h.SMTRoot)))
	}
}

// Persist stores a new head and the versions it publishes before anyone can
// see them. If it fails the directory's state is ahead of storage: the caller
// must stop (and restore from storage on restart).
type Persist func(head Head, published map[string][]Version) error

// CheckRestored confirms the restored tree is the one the last stored head
// signed for.
func (d *Directory) CheckRestored() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.heads) == 0 {
		return nil
	}
	last := d.heads[len(d.heads)-1]
	if d.smt.Root() != last.SMTRoot || LogRoot(d.logLeaves) != last.LogRoot {
		return ErrNotInTree
	}
	return nil
}

// Publish makes the pending versions visible as a new epoch, if there are
// any (or nothing was published yet). Returns the head and whether it's new.
// Lookups wait while persist runs, so an unsaved head is never served.
func (d *Directory) Publish(now time.Time, persist Persist) (Head, bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.dirty && len(d.heads) > 0 {
		return d.heads[len(d.heads)-1], false, nil
	}
	epoch := uint64(len(d.heads) + 1)
	published := map[string][]Version{}
	for account, history := range d.accounts {
		changed := false
		for i := range history {
			if history[i].Epoch == 0 {
				history[i].Epoch = epoch
				published[account] = append(published[account], history[i])
				changed = true
			}
		}
		if changed {
			label, _ := d.label(account)
			d.smt.Set(label, history[len(history)-1].Chain)
		}
	}
	root := d.smt.Root()
	d.logLeaves = append(d.logLeaves, logLeafHash(LogEntry(epoch, root)))
	head := Head{
		Epoch: epoch, SMTRoot: root,
		LogSize: uint64(len(d.logLeaves)), LogRoot: LogRoot(d.logLeaves),
		Time: uint64(now.Unix()),
	}
	head.Sign(d.signKey)
	if persist != nil {
		if err := persist(head, published); err != nil {
			return Head{}, false, err
		}
	}
	d.heads = append(d.heads, head)
	d.dirty = false
	return head, true, nil
}

// Sync records every account's current keys: accounts missing from `current`
// commit to no keys (deleted). Returns how many versions it added.
func (d *Directory) Sync(current map[string][][]byte) (int, error) {
	d.mu.RLock()
	var gone []string
	for account, history := range d.accounts {
		if _, ok := current[account]; !ok && len(history) > 0 && len(history[len(history)-1].Keys) > 0 {
			gone = append(gone, account)
		}
	}
	d.mu.RUnlock()
	added := 0
	for account, keys := range current {
		changed, err := d.SetKeys(account, keys)
		if err != nil {
			return added, err
		}
		if changed {
			added++
		}
	}
	for _, account := range gone {
		if changed, err := d.SetKeys(account, nil); err != nil {
			return added, err
		} else if changed {
			added++
		}
	}
	return added, nil
}

// PublicKeys are what clients verify against.
func (d *Directory) PublicKeys() (*rsa.PublicKey, ed25519.PublicKey) {
	return &d.vrfKey.PublicKey, d.signKey.Public().(ed25519.PublicKey)
}

// Head is the latest published head.
func (d *Directory) Head() (Head, bool) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	if len(d.heads) == 0 {
		return Head{}, false
	}
	return d.heads[len(d.heads)-1], true
}

// Link is one version's place in an account's chain: enough to recompute the
// chain without seeing the keys.
type Link struct {
	Version    uint32
	Commitment [32]byte
}

// LookupResult is what a client needs to check an account's current keys.
type LookupResult struct {
	// Links after the version the client last saw (Since), oldest first,
	// through the current one, so it can check the history only grew.
	Links      []Link
	VRFProof   []byte
	Version    uint32 // 0: the account isn't in the directory
	Commitment [32]byte
	PrevChain  [32]byte
	Nonce      [32]byte
	Keys       [][]byte
	Proof      Proof
	Head       Head
}

var ErrNotPublished = errors.New("kt: nothing published yet")

// LookupSince is Lookup plus the links after version `since`.
func (d *Directory) LookupSince(account string, since uint32) (LookupResult, error) {
	r, err := d.Lookup(account)
	if err != nil {
		return r, err
	}
	d.mu.RLock()
	defer d.mu.RUnlock()
	for _, v := range d.accounts[account] {
		if v.Epoch != 0 && v.Version > since && v.Version <= r.Version {
			r.Links = append(r.Links, Link{Version: v.Version, Commitment: v.Commitment})
		}
	}
	return r, nil
}

// Lookup proves the account's latest published version (or its absence).
func (d *Directory) Lookup(account string) (LookupResult, error) {
	d.mu.Lock() // label() may fill the cache
	defer d.mu.Unlock()
	if len(d.heads) == 0 {
		return LookupResult{}, ErrNotPublished
	}
	label, pi := d.label(account)
	r := LookupResult{VRFProof: pi, Head: d.heads[len(d.heads)-1], Proof: d.smt.Prove(label)}
	history := d.accounts[account]
	for i := len(history) - 1; i >= 0; i-- {
		if history[i].Epoch == 0 {
			continue
		}
		v := history[i]
		r.Version, r.Commitment, r.Nonce, r.Keys = v.Version, v.Commitment, v.Nonce, v.Keys
		if i > 0 {
			r.PrevChain = history[i-1].Chain
		}
		break
	}
	return r, nil
}

// History is the account's published versions, oldest first, for its owner.
func (d *Directory) History(account string) []Version {
	d.mu.RLock()
	defer d.mu.RUnlock()
	var out []Version
	for _, v := range d.accounts[account] {
		if v.Epoch != 0 {
			out = append(out, v)
		}
	}
	return out
}

// Consistency proves the log at size `to` extends the log at size `from`.
func (d *Directory) Consistency(from, to uint64) ([][32]byte, error) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	if from < 1 || to > uint64(len(d.logLeaves)) || from > to {
		return nil, errConsistency
	}
	return ConsistencyProof(d.logLeaves[:to], int(from)), nil
}

// MARK: client checks (mirrored by the app)

var (
	ErrHeadSignature = errors.New("kt: head signature is invalid")
	ErrKeyMismatch   = errors.New("kt: key isn't the one in the directory")
	ErrNotInTree     = errors.New("kt: entry doesn't match the tree")
)

// VerifyLookup checks a lookup for `account` and, if bundleKey is set, that
// it's one of the account's keys in the directory.
func VerifyLookup(vrfPub *rsa.PublicKey, signPub ed25519.PublicKey, account string,
	bundleKey []byte, r LookupResult) error {
	if !r.Head.Verify(signPub) {
		return ErrHeadSignature
	}
	label, err := VRFVerify(vrfPub, []byte(account), r.VRFProof)
	if err != nil {
		return err
	}
	if r.Version == 0 {
		root, err := RootFromProof(label, nil, r.Proof)
		if err != nil || root != r.Head.SMTRoot {
			return ErrNotInTree
		}
		if bundleKey != nil {
			return ErrKeyMismatch
		}
		return nil
	}
	if Commit(r.Nonce, r.Keys) != r.Commitment {
		return ErrKeyMismatch
	}
	if bundleKey != nil {
		found := false
		for _, k := range r.Keys {
			if bytes.Equal(k, bundleKey) {
				found = true
			}
		}
		if !found {
			return ErrKeyMismatch
		}
	}
	chain := Chain(r.PrevChain, r.Version, r.Commitment)
	root, err := RootFromProof(label, &chain, r.Proof)
	if err != nil || root != r.Head.SMTRoot {
		return ErrNotInTree
	}
	return nil
}

// VerifyExtends checks the lookup's history grew from (version, chain), a
// state the client accepted before: the server can't swap a key and later
// swap it back without breaking the chain the client remembers.
func VerifyExtends(version uint32, chain [32]byte, r LookupResult) error {
	if r.Version < version {
		return ErrNotInTree
	}
	latest := Chain(r.PrevChain, r.Version, r.Commitment)
	if r.Version == version {
		if latest != chain {
			return ErrNotInTree
		}
		return nil
	}
	c := chain
	next := version + 1
	for _, l := range r.Links {
		if l.Version != next {
			return ErrNotInTree
		}
		c = Chain(c, l.Version, l.Commitment)
		next++
	}
	if next != r.Version+1 || c != latest {
		return ErrNotInTree
	}
	return nil
}

// VerifyHistory checks an owner's version list is one unbroken chain ending at
// the latest lookup's chain value, and returns every key set it ever held.
func VerifyHistory(versions []Version, latest LookupResult) ([][][]byte, error) {
	var prev [32]byte
	var sets [][][]byte
	for i, v := range versions {
		if v.Version != uint32(i+1) || Commit(v.Nonce, v.Keys) != v.Commitment {
			return nil, ErrNotInTree
		}
		prev = Chain(prev, v.Version, v.Commitment)
		sets = append(sets, v.Keys)
	}
	if len(versions) != int(latest.Version) || prev != Chain(latest.PrevChain, latest.Version, latest.Commitment) {
		return nil, ErrNotInTree
	}
	return sets, nil
}
