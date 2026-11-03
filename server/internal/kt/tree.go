package kt

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"math/big"
	"sort"
)

func randInt(max *big.Int) (*big.Int, error) {
	for {
		r, err := rand.Int(rand.Reader, max)
		if err != nil {
			return nil, err
		}
		if r.Sign() > 0 {
			return r, nil
		}
	}
}

// MARK: commitments and chains

// Commit hides an account's keys: SHA256("relay-kt-commit" ‖ nonce ‖ keys),
// keys sorted, each as a 2-byte length and the bytes.
func Commit(nonce [32]byte, keys [][]byte) [32]byte {
	sorted := make([][]byte, len(keys))
	copy(sorted, keys)
	sort.Slice(sorted, func(i, j int) bool { return bytes.Compare(sorted[i], sorted[j]) < 0 })
	h := sha256.New()
	h.Write([]byte("relay-kt-commit"))
	h.Write(nonce[:])
	for _, k := range sorted {
		var n [2]byte
		binary.BigEndian.PutUint16(n[:], uint16(len(k)))
		h.Write(n[:])
		h.Write(k)
	}
	var out [32]byte
	h.Sum(out[:0])
	return out
}

// Chain links version v onto the account's history.
func Chain(prev [32]byte, version uint32, commitment [32]byte) [32]byte {
	h := sha256.New()
	h.Write([]byte("relay-kt-chain"))
	h.Write(prev[:])
	var v [4]byte
	binary.BigEndian.PutUint32(v[:], version)
	h.Write(v[:])
	h.Write(commitment[:])
	var out [32]byte
	h.Sum(out[:0])
	return out
}

// MARK: sparse Merkle tree

const depth = 256

var emptyHash [depth + 1][32]byte

func init() {
	for d := depth - 1; d >= 0; d-- {
		emptyHash[d] = innerHash(emptyHash[d+1], emptyHash[d+1])
	}
}

func leafHash(label, value [32]byte) [32]byte {
	h := sha256.New()
	h.Write([]byte{0x00})
	h.Write(label[:])
	h.Write(value[:])
	var out [32]byte
	h.Sum(out[:0])
	return out
}

func innerHash(left, right [32]byte) [32]byte {
	h := sha256.New()
	h.Write([]byte{0x01})
	h.Write(left[:])
	h.Write(right[:])
	var out [32]byte
	h.Sum(out[:0])
	return out
}

func bit(label [32]byte, i int) int {
	return int(label[i/8]>>(7-uint(i%8))) & 1
}

// SMT is the label → chain map for one epoch. Root caches every non-empty
// node's hash, so a proof afterwards is a few hundred map reads.
type SMT struct {
	leaves map[[32]byte][32]byte
	nodes  map[nodeKey][32]byte // nil until Root runs after a change
	lone   map[nodeKey][32]byte // nodes that hold a single leaf → its label
}

type nodeKey struct {
	depth  int
	prefix [32]byte // the label's first `depth` bits, the rest zero
}

func keyFor(label [32]byte, d int) nodeKey {
	k := nodeKey{depth: d}
	for i := 0; i < d/8; i++ {
		k.prefix[i] = label[i]
	}
	if d%8 != 0 {
		k.prefix[d/8] = label[d/8] & byte(0xFF<<(8-uint(d%8)))
	}
	return k
}

func NewSMT() *SMT { return &SMT{leaves: map[[32]byte][32]byte{}} }

func (t *SMT) Set(label, value [32]byte) {
	t.leaves[label] = value
	t.nodes = nil
}

func (t *SMT) Len() int { return len(t.leaves) }

func (t *SMT) sortedLabels() [][32]byte {
	labels := make([][32]byte, 0, len(t.leaves))
	for l := range t.leaves {
		labels = append(labels, l)
	}
	sort.Slice(labels, func(i, j int) bool { return bytes.Compare(labels[i][:], labels[j][:]) < 0 })
	return labels
}

// Root hashes the tree.
func (t *SMT) Root() [32]byte {
	if t.nodes == nil {
		t.nodes = map[nodeKey][32]byte{}
		t.lone = map[nodeKey][32]byte{}
		t.subtree(t.sortedLabels(), 0)
	}
	if h, ok := t.nodes[nodeKey{}]; ok {
		return h
	}
	return emptyHash[0]
}

// subtree hashes the labels (sorted, all sharing their first d bits) at depth d.
func (t *SMT) subtree(labels [][32]byte, d int) [32]byte {
	if len(labels) == 0 {
		return emptyHash[d]
	}
	h := t.subtreeUncached(labels, d)
	if t.nodes != nil {
		t.nodes[keyFor(labels[0], d)] = h
		if len(labels) == 1 {
			t.lone[keyFor(labels[0], d)] = labels[0]
		}
	}
	return h
}

// liftLeaf hashes a lone leaf up to depth d.
func (t *SMT) liftLeaf(label [32]byte, d int) [32]byte {
	h := leafHash(label, t.leaves[label])
	for level := depth - 1; level >= d; level-- {
		if bit(label, level) == 0 {
			h = innerHash(h, emptyHash[level+1])
		} else {
			h = innerHash(emptyHash[level+1], h)
		}
	}
	return h
}

func (t *SMT) subtreeUncached(labels [][32]byte, d int) [32]byte {
	if len(labels) == 1 {
		// One leaf: hash it up through empty siblings.
		label := labels[0]
		h := leafHash(label, t.leaves[label])
		for level := depth - 1; level >= d; level-- {
			if bit(label, level) == 0 {
				h = innerHash(h, emptyHash[level+1])
			} else {
				h = innerHash(emptyHash[level+1], h)
			}
		}
		return h
	}
	split := sort.Search(len(labels), func(i int) bool { return bit(labels[i], d) == 1 })
	return innerHash(t.subtree(labels[:split], d+1), t.subtree(labels[split:], d+1))
}

// Proof is the siblings on the way from a leaf to the root, top first, with
// empty subtrees left out: bit i of Bitmap set means Siblings holds depth i+1's.
type Proof struct {
	Bitmap   [32]byte
	Siblings [][32]byte
}

// Prove returns the path for label; the leaf may be absent (then the proof
// shows the empty leaf at that position).
func (t *SMT) Prove(label [32]byte) Proof {
	t.Root() // fills the node cache
	var p Proof
	for d := 0; d < depth; d++ {
		// The path reaches a node holding one leaf: if it isn't this label,
		// that leaf is the only non-empty sibling left, where they part.
		if other, ok := t.lone[keyFor(label, d)]; ok {
			if other != label {
				k := d
				for bit(other, k) == bit(label, k) {
					k++
				}
				p.Bitmap[k/8] |= 1 << (7 - uint(k%8))
				p.Siblings = append(p.Siblings, t.liftLeaf(other, k+1))
			}
			break
		}
		sibling := label
		sibling[d/8] ^= 1 << (7 - uint(d%8))
		h, ok := t.nodes[keyFor(sibling, d+1)]
		if !ok {
			// Below the last shared node the path is a lone leaf or empty.
			if _, onPath := t.nodes[keyFor(label, d+1)]; !onPath {
				break
			}
			continue
		}
		p.Bitmap[d/8] |= 1 << (7 - uint(d%8))
		p.Siblings = append(p.Siblings, h)
	}
	return p
}

var errProof = errors.New("kt: bad proof")

// RootFromProof is the root implied by leaf (label, value) and its path. A nil
// value means "this label is absent".
func RootFromProof(label [32]byte, value *[32]byte, p Proof) ([32]byte, error) {
	set := 0
	for d := 0; d < depth; d++ {
		if p.Bitmap[d/8]&(1<<(7-uint(d%8))) != 0 {
			set++
		}
	}
	if set != len(p.Siblings) {
		return [32]byte{}, errProof
	}
	h := emptyHash[depth]
	if value != nil {
		h = leafHash(label, *value)
	}
	next := len(p.Siblings) - 1
	for d := depth - 1; d >= 0; d-- {
		sibling := emptyHash[d+1]
		if p.Bitmap[d/8]&(1<<(7-uint(d%8))) != 0 {
			sibling = p.Siblings[next]
			next--
		}
		if bit(label, d) == 0 {
			h = innerHash(h, sibling)
		} else {
			h = innerHash(sibling, h)
		}
	}
	return h, nil
}
