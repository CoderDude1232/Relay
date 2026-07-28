// Package hub routes envelopes to connected devices and hands offline
// recipients over to the store's message queue.
//
// Delivery is at-least-once: every non-ephemeral envelope is persisted
// before any delivery attempt and deleted only when the recipient acks it.
package hub

import (
	"fmt"
	"log/slog"
	"sync"

	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/store"
	"google.golang.org/protobuf/proto"
)

// Session is one live device connection. Send must not block the hub:
// implementations buffer writes and report false when the buffer is full
// or the connection is gone (the envelope stays queued for later).
type Session interface {
	Send(frame *relaypb.ServerFrame) bool
}

type Hub struct {
	store *store.Store

	mu       sync.RWMutex
	sessions map[string]Session // key: accountID/deviceID
}

func New(st *store.Store) *Hub {
	return &Hub{store: st, sessions: make(map[string]Session)}
}

func key(accountID string, deviceID uint32) string {
	return fmt.Sprintf("%s/%d", accountID, deviceID)
}

// Register attaches a live session and returns any envelopes queued while
// the device was offline (already serialized), oldest first. The caller
// delivers them, then sends QueueEmpty.
func (h *Hub) Register(accountID string, deviceID uint32, s Session) ([][]byte, error) {
	h.mu.Lock()
	h.sessions[key(accountID, deviceID)] = s
	h.mu.Unlock()
	return h.store.QueuedEnvelopes(accountID, deviceID)
}

// Unregister detaches a session if it is still the current one for the
// device (a reconnect may already have replaced it).
func (h *Hub) Unregister(accountID string, deviceID uint32, s Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	k := key(accountID, deviceID)
	if h.sessions[k] == s {
		delete(h.sessions, k)
	}
}

// Deliver routes one envelope to one device. Non-ephemeral envelopes are
// queued first so a crash between here and the socket write loses nothing.
func (h *Hub) Deliver(accountID string, deviceID uint32, env *relaypb.Envelope) error {
	frame := &relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Envelope{Envelope: env}}

	if !env.Ephemeral {
		blob, err := proto.Marshal(env)
		if err != nil {
			return err
		}
		if err := h.store.Enqueue(env.Id, accountID, deviceID, blob); err != nil {
			return err
		}
	}

	h.mu.RLock()
	s := h.sessions[key(accountID, deviceID)]
	h.mu.RUnlock()
	if s != nil {
		if !s.Send(frame) {
			slog.Debug("hub: session backlogged, envelope stays queued",
				"account", accountID, "device", deviceID)
		}
	}
	return nil
}

// Ack removes a delivered envelope from the device's queue.
func (h *Hub) Ack(accountID string, deviceID uint32, envelopeID string) error {
	return h.store.Dequeue(envelopeID, accountID, deviceID)
}
