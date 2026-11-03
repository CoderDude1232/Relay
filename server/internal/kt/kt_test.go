package kt

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"fmt"
	"sync"
	"testing"
	"time"
)

var (
	testKeysOnce sync.Once
	testVRFKey   *rsa.PrivateKey
	testSignKey  ed25519.PrivateKey
)

func keys(t *testing.T) (*rsa.PrivateKey, ed25519.PrivateKey) {
	testKeysOnce.Do(func() {
		var err error
		if testVRFKey, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
			t.Fatal(err)
		}
		_, testSignKey, _ = ed25519.GenerateKey(rand.Reader)
	})
	return testVRFKey, testSignKey
}

func TestVRF(t *testing.T) {
	sk, _ := keys(t)
	pi := VRFProve(sk, []byte("alice"))
	label, err := VRFVerify(&sk.PublicKey, []byte("alice"), pi)
	if err != nil || label != VRFHash(pi) {
		t.Fatalf("verify: %v", err)
	}
	// Deterministic: the same input gives the same label.
	if VRFHash(VRFProve(sk, []byte("alice"))) != label {
		t.Fatal("not deterministic")
	}
	if _, err := VRFVerify(&sk.PublicKey, []byte("bob"), pi); err == nil {
		t.Fatal("proof accepted for another input")
	}
	pi[10] ^= 1
	if _, err := VRFVerify(&sk.PublicKey, []byte("alice"), pi); err == nil {
		t.Fatal("tampered proof accepted")
	}
}

func TestSMTProofs(t *testing.T) {
	tree := NewSMT()
	var labels [][32]byte
	for i := 0; i < 50; i++ {
		var l, v [32]byte
		rand.Read(l[:])
		rand.Read(v[:])
		tree.Set(l, v)
		labels = append(labels, l)
	}
	root := tree.Root()
	for _, l := range labels[:10] {
		v := tree.leaves[l]
		got, err := RootFromProof(l, &v, tree.Prove(l))
		if err != nil || got != root {
			t.Fatal("inclusion proof failed")
		}
		wrong := v
		wrong[0] ^= 1
		if got, _ := RootFromProof(l, &wrong, tree.Prove(l)); got == root {
			t.Fatal("wrong value accepted")
		}
	}
	var absent [32]byte
	rand.Read(absent[:])
	if got, err := RootFromProof(absent, nil, tree.Prove(absent)); err != nil || got != root {
		t.Fatal("absence proof failed")
	}
	if got, _ := RootFromProof(labels[0], nil, tree.Prove(labels[0])); got == root {
		t.Fatal("absence accepted for a present label")
	}
	if NewSMT().Root() != emptyHash[0] {
		t.Fatal("empty root")
	}
}

func TestLogConsistency(t *testing.T) {
	var leaves [][32]byte
	for i := 0; i < 40; i++ {
		leaves = append(leaves, logLeafHash(LogEntry(uint64(i+1), [32]byte{byte(i)})))
	}
	for n := 1; n <= len(leaves); n++ {
		for m := 1; m <= n; m++ {
			proof := ConsistencyProof(leaves[:n], m)
			if err := VerifyConsistency(m, n, LogRoot(leaves[:m]), LogRoot(leaves[:n]), proof); err != nil {
				t.Fatalf("m=%d n=%d: %v", m, n, err)
			}
		}
	}
	// A rewritten history fails.
	forked := append([][32]byte{}, leaves[:20]...)
	forked[3] = logLeafHash([]byte("fork"))
	if VerifyConsistency(10, 20, LogRoot(forked[:10]), LogRoot(leaves[:20]), ConsistencyProof(leaves[:20], 10)) == nil {
		t.Fatal("forked log accepted")
	}
}

func TestDirectoryLookupAndHistory(t *testing.T) {
	vrfKey, signKey := keys(t)
	pub := signKey.Public().(ed25519.PublicKey)
	d := NewDirectory(vrfKey, signKey)
	for i := 0; i < 20; i++ {
		d.SetKeys(fmt.Sprintf("acct-%d", i), [][]byte{[]byte(fmt.Sprintf("key-%d", i))})
	}
	if _, err := d.Lookup("acct-1"); err != ErrNotPublished {
		t.Fatal("lookup before publish")
	}
	h1, _, _ := d.Publish(time.Now(), nil)

	r, err := d.Lookup("acct-3")
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyLookup(&vrfKey.PublicKey, pub, "acct-3", []byte("key-3"), r); err != nil {
		t.Fatalf("valid lookup rejected: %v", err)
	}
	if VerifyLookup(&vrfKey.PublicKey, pub, "acct-3", []byte("someone-elses-key"), r) != ErrKeyMismatch {
		t.Fatal("wrong bundle key accepted")
	}
	if VerifyLookup(&vrfKey.PublicKey, pub, "acct-4", nil, r) == nil {
		t.Fatal("lookup accepted for another account")
	}
	// A server swapping the key without updating the tree is caught.
	forged := r
	forged.Keys = [][]byte{[]byte("evil")}
	forged.Commitment = Commit(forged.Nonce, forged.Keys)
	if VerifyLookup(&vrfKey.PublicKey, pub, "acct-3", []byte("evil"), forged) != ErrNotInTree {
		t.Fatal("forged key accepted")
	}

	// Unknown accounts get a verifiable absence.
	none, _ := d.Lookup("nobody")
	if none.Version != 0 || VerifyLookup(&vrfKey.PublicKey, pub, "nobody", nil, none) != nil {
		t.Fatal("absence")
	}

	// A key change is a new version; pending until published.
	if changed, _ := d.SetKeys("acct-3", [][]byte{[]byte("key-3b")}); !changed {
		t.Fatal("change not recorded")
	}
	if r, _ := d.Lookup("acct-3"); r.Version != 1 {
		t.Fatal("unpublished version visible")
	}
	h2, _, _ := d.Publish(time.Now(), nil)
	r2, _ := d.Lookup("acct-3")
	if r2.Version != 2 || VerifyLookup(&vrfKey.PublicKey, pub, "acct-3", []byte("key-3b"), r2) != nil {
		t.Fatal("new version")
	}
	sets, err := VerifyHistory(d.History("acct-3"), r2)
	if err != nil || len(sets) != 2 || string(sets[0][0]) != "key-3" {
		t.Fatalf("history: %v", err)
	}

	// Unchanged keys don't make a version; an idle publish keeps the head.
	if changed, _ := d.SetKeys("acct-5", [][]byte{[]byte("key-5")}); changed {
		t.Fatal("no-op change recorded")
	}
	if _, isNew, _ := d.Publish(time.Now(), nil); isNew {
		t.Fatal("empty epoch published")
	}

	// The second head extends the first.
	proof, err := d.Consistency(h1.LogSize, h2.LogSize)
	if err != nil || VerifyConsistency(int(h1.LogSize), int(h2.LogSize), h1.LogRoot, h2.LogRoot, proof) != nil {
		t.Fatal("consistency between heads")
	}
}
