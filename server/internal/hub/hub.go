// Package hub routes envelopes to connected devices and hands offline
// recipients over to the store's message queue.
//
// Delivery is at-least-once: every non-ephemeral envelope is persisted
// before any delivery attempt and deleted only when the recipient acks it.
package hub

import (
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/privlog"
	"github.com/relayapp/relay-server/internal/store"
	"google.golang.org/protobuf/proto"
)

// Session is one live device connection. Send must not block the hub:
// implementations buffer writes and report false when the buffer is full
// or the connection is gone (the envelope stays queued for later).
type Session interface {
	Send(frame *relaypb.ServerFrame) bool
}

// Pusher wakes an offline device via APNs, carrying the encrypted envelope
// for its Notification Service Extension to decrypt. Optional; nil disables
// push (the envelope still queues for delivery on next connect).
type Pusher interface {
	Push(deviceToken string, envelope []byte) error
}

// FCMPusher wakes an offline Android device via Firebase Cloud Messaging. Same
// contract as Pusher: a nil/empty envelope is a content-free data-only wake; a
// non-nil envelope is carried for the opt-in ciphertext-in-push case. Optional.
type FCMPusher interface {
	Push(deviceToken string, envelope []byte) error
}

// VoIPPusher sends a PushKit VoIP push to wake the app and present the
// CallKit incoming-call UI. Optional; nil means calls only work in-foreground.
type VoIPPusher interface {
	PushVoIP(deviceToken, callID, callerAccount, callerName, kind string) error
}

type Hub struct {
	store      *store.Store
	pusher     Pusher
	fcmPusher  FCMPusher
	voipPusher VoIPPusher

	mu       sync.RWMutex
	sessions map[string]Session // key: accountID/deviceID
	// lastSeen is intentionally kept in-memory only.
	// Writing activity timestamps to disk would create metadata a warrant
	// could retrieve; losing them on restart is an acceptable trade-off.
	lastSeen map[string]int64 // accountID → Unix ms
}

func New(st *store.Store) *Hub {
	return &Hub{
		store:    st,
		sessions: make(map[string]Session),
		lastSeen: make(map[string]int64),
	}
}

// SetPusher attaches an APNs sender used to wake offline devices.
func (h *Hub) SetPusher(p Pusher) { h.pusher = p }

// SetFCMPusher attaches a Firebase Cloud Messaging sender for Android devices.
func (h *Hub) SetFCMPusher(p FCMPusher) { h.fcmPusher = p }

// SetVoIPPusher attaches a PushKit sender for incoming-call wakes.
func (h *Hub) SetVoIPPusher(p VoIPPusher) { h.voipPusher = p }

// PushCallToAccount sends a VoIP push to every device of accountID.
func (h *Hub) PushCallToAccount(accountID, callID, callerAccount, callerName, kind string) {
	if h.voipPusher == nil {
		return
	}
	tokens, err := h.store.VoIPTokensForAccount(accountID)
	if err != nil || len(tokens) == 0 {
		if err != nil {
			slog.Warn("voip: token lookup failed", "err", privlog.Error(err))
		} else {
			slog.Info("voip: no tokens for account")
		}
		return
	}
	for _, token := range tokens {
		t := token
		go func() {
			if err := h.voipPusher.PushVoIP(t, callID, callerAccount, callerName, kind); err != nil {
				slog.Warn("voip push failed", "err", privlog.Error(err))
			} else {
				slog.Info("voip push sent")
			}
		}()
	}
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
	h.lastSeen[accountID] = time.Now().UnixMilli()
	h.mu.Unlock()
	slog.Info("ws: session registered")
	return h.store.QueuedEnvelopes(accountID, deviceID)
}

// IsOnline reports whether any device of the account has a live session.
func (h *Hub) IsOnline(accountID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	prefix := accountID + "/"
	for k := range h.sessions {
		if strings.HasPrefix(k, prefix) {
			return true
		}
	}
	return false
}

// Unregister detaches a session if it is still the current one for the
// device (a reconnect may already have replaced it).
func (h *Hub) Unregister(accountID string, deviceID uint32, s Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	k := key(accountID, deviceID)
	if h.sessions[k] == s {
		delete(h.sessions, k)
		slog.Info("ws: session unregistered")
		h.lastSeen[accountID] = time.Now().UnixMilli()
	}
}

// LastSeen returns the most recent connect/disconnect time for the account
// in milliseconds since epoch, or 0 if not seen since server start.
// This is intentionally in-memory only — never persisted to disk.
func (h *Hub) LastSeen(accountID string) int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.lastSeen[accountID]
}

// Deliver routes one envelope to one device. Non-ephemeral envelopes are
// queued first so a crash between here and the socket write loses nothing.
func (h *Hub) Deliver(accountID string, deviceID uint32, env *relaypb.Envelope) error {
	frame := &relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Envelope{Envelope: env}}

	var blob []byte
	if !env.Ephemeral {
		var err error
		blob, err = proto.Marshal(env)
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
			// Socket is full or already gone (close frame not yet processed).
			// The envelope is already queued; also fire an APNs push so the
			// device wakes immediately rather than waiting for the 60s pong
			// timeout to expire and the next reconnect to drain the queue.
			slog.Debug("hub: session backlogged, also pushing")
			if h.pusher != nil && !env.Ephemeral {
				h.notifyOffline(accountID, deviceID, blob)
			}
		}
		return nil
	}

	// Offline: wake the device via APNs so its NSE can decrypt the envelope.
	if h.pusher != nil && !env.Ephemeral {
		h.notifyOffline(accountID, deviceID, blob)
	}
	return nil
}

func (h *Hub) notifyOffline(accountID string, deviceID uint32, envelope []byte) {
	kind, token, err := h.store.PushTarget(accountID, deviceID)
	if err != nil || token == "" {
		if err != nil {
			slog.Warn("push: token lookup failed", "err", privlog.Error(err))
		} else {
			slog.Info("push: offline device has no token")
		}
		return
	}

	// Pick the transport registered by this device. If its sender isn't
	// configured on this server, the envelope still delivers on next connect.
	var send func(string, []byte) error
	switch kind {
	case "fcm":
		if h.fcmPusher == nil {
			slog.Info("push: fcm device but no fcm sender configured")
			return
		}
		send = h.fcmPusher.Push
	default:
		if h.pusher == nil {
			return
		}
		send = h.pusher.Push
	}

	// Content-free wake by default: the device fetches + decrypts the envelope
	// from the relay, so the push provider never carries message data. A device
	// may opt in to ciphertext-in-push (faster) via its push-content preference.
	payload := []byte(nil)
	if include, err := h.store.PushIncludeContent(accountID, deviceID); err != nil {
		slog.Warn("push: push-content lookup failed", "err", privlog.Error(err))
	} else if include {
		payload = envelope
	}
	slog.Info("push: waking offline device", "kind", kind)
	go func() {
		if err := send(token, payload); err != nil {
			slog.Warn("push failed", "kind", kind, "err", privlog.Error(err))
		} else {
			slog.Info("push sent", "kind", kind)
		}
	}()
}

// BroadcastNuke sends a NukeCommand frame to every live session of the account.
// Connected devices self-destruct immediately; offline devices receive it on reconnect.
func (h *Hub) BroadcastNuke(accountID string, nuke *relaypb.NukeCommand) {
	frame := &relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Nuke{Nuke: nuke}}
	h.broadcastToAccount(accountID, frame)
}

// BroadcastDeviceListChanged notifies every live session of the account except
// the initiating device that the device list changed.
func (h *Hub) BroadcastDeviceListChanged(accountID string, exceptDeviceID uint32, action relaypb.DeviceListChanged_Action, changedDeviceID uint32) {
	frame := &relaypb.ServerFrame{Payload: &relaypb.ServerFrame_DeviceListChanged{
		DeviceListChanged: &relaypb.DeviceListChanged{Action: action, DeviceId: changedDeviceID},
	}}
	h.mu.RLock()
	defer h.mu.RUnlock()
	prefix := accountID + "/"
	for k, s := range h.sessions {
		if strings.HasPrefix(k, prefix) && k != key(accountID, exceptDeviceID) {
			s.Send(frame)
		}
	}
}

func (h *Hub) broadcastToAccount(accountID string, frame *relaypb.ServerFrame) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	prefix := accountID + "/"
	for k, s := range h.sessions {
		if strings.HasPrefix(k, prefix) {
			s.Send(frame)
		}
	}
}

// Ack removes a delivered envelope from the device's queue.
func (h *Hub) Ack(accountID string, deviceID uint32, envelopeID string) error {
	return h.store.Dequeue(envelopeID, accountID, deviceID)
}
