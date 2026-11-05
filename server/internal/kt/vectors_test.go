package kt

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"
)

// TestWriteVectors writes lookups, histories and consistency proofs for the
// app's tests to check against (KT_VECTORS=path go test -run WriteVectors).
func TestWriteVectors(t *testing.T) {
	path := os.Getenv("KT_VECTORS")
	if path == "" {
		t.Skip("set KT_VECTORS to write test vectors")
	}
	vrfKey, signKey := keys(t)
	d := NewDirectory(vrfKey, signKey)
	b := base64.StdEncoding.EncodeToString
	head := func(h Head) map[string]any {
		return map[string]any{"epoch": h.Epoch, "smtRoot": b(h.SMTRoot[:]), "logSize": h.LogSize,
			"logRoot": b(h.LogRoot[:]), "time": h.Time, "sig": b(h.Sig)}
	}
	lookup := func(r LookupResult) map[string]any {
		sibs := []string{}
		for _, s := range r.Proof.Siblings {
			sibs = append(sibs, b(s[:]))
		}
		ks := []string{}
		for _, k := range r.Keys {
			ks = append(ks, b(k))
		}
		links := []map[string]any{}
		for _, l := range r.Links {
			links = append(links, map[string]any{"version": l.Version, "commitment": b(l.Commitment[:])})
		}
		return map[string]any{"links": links, "vrfProof": b(r.VRFProof), "version": r.Version, "commitment": b(r.Commitment[:]),
			"prevChain": b(r.PrevChain[:]), "nonce": b(r.Nonce[:]), "keys": ks,
			"proof": map[string]any{"bitmap": b(r.Proof.Bitmap[:]), "siblings": sibs}, "head": head(r.Head)}
	}

	var heads []Head
	for i := 0; i < 30; i++ {
		d.SetKeys(fmt.Sprintf("acct-%d", i), [][]byte{[]byte(fmt.Sprintf("key-%d", i))})
	}
	h, _, _ := d.Publish(time.Now(), nil)
	heads = append(heads, h)
	first, _ := d.Lookup("acct-7")
	for e := 0; e < 6; e++ {
		d.SetKeys("acct-7", [][]byte{[]byte(fmt.Sprintf("key-7-v%d", e+2))})
		h, _, _ = d.Publish(time.Now(), nil)
		heads = append(heads, h)
	}
	latest, _ := d.Lookup("acct-7")
	grown, _ := d.LookupSince("acct-7", first.Version)
	firstChain := Chain(first.PrevChain, first.Version, first.Commitment)
	absent, _ := d.Lookup("nobody")

	var history []map[string]any
	for _, v := range d.History("acct-7") {
		ks := []string{}
		for _, k := range v.Keys {
			ks = append(ks, b(k))
		}
		history = append(history, map[string]any{"version": v.Version, "commitment": b(v.Commitment[:]),
			"nonce": b(v.Nonce[:]), "keys": ks, "epoch": v.Epoch})
	}
	var consistency []map[string]any
	for _, pair := range [][2]int{{1, 7}, {3, 7}, {4, 6}, {2, 5}, {7, 7}} {
		proof, _ := d.Consistency(uint64(pair[0]), uint64(pair[1]))
		ps := []string{}
		for _, p := range proof {
			ps = append(ps, b(p[:]))
		}
		consistency = append(consistency, map[string]any{"from": head(heads[pair[0]-1]), "to": head(heads[pair[1]-1]), "proof": ps})
	}
	// A replacement signing key the test key endorses, and a head it signed.
	_, next, _ := ed25519.GenerateKey(nil)
	endorsed := Endorse("head", signKey, next.Public().(ed25519.PublicKey))
	rotated := Head{Epoch: 99, LogSize: 99, Time: 1}
	rotated.Sign(next)
	out, _ := json.MarshalIndent(map[string]any{
		"endorsement":       map[string]any{"key": b(endorsed.Key), "by": b(endorsed.By), "sig": b(endorsed.Sig)},
		"rotatedHead":       head(rotated),
		"vrfPublicKeyPKCS1": b(x509.MarshalPKCS1PublicKey(&vrfKey.PublicKey)),
		"signPublicKey":     b(signKey.Public().(ed25519.PublicKey)),
		"first":             map[string]any{"account": "acct-7", "key": b([]byte("key-7")), "lookup": lookup(first)},
		"latest":            map[string]any{"account": "acct-7", "key": b([]byte("key-7-v7")), "lookup": lookup(latest)},
		"absent":            map[string]any{"account": "nobody", "lookup": lookup(absent)},
		"extends":           map[string]any{"version": first.Version, "chain": b(firstChain[:]), "lookup": lookup(grown)},
		"history":           history,
		"consistency":       consistency,
	}, "", " ")
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}
