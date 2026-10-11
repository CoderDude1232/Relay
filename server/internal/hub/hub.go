// Package hub routes envelopes to connected devices and hands offline
// recipients over to the store's message queue.
//
// Delivery is at-least-once: every non-ephemeral envelope is persisted
// before any delivery attempt and deleted only when the recipient acks it.
package hub

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/limitkey"
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
	// PushCall wakes an Android device for an incoming call (the FCM analogue of
	// PushKit): a high-priority data message carrying only the call id.
	PushCall(deviceToken, callID string) error
}

// VoIPPusher sends a PushKit VoIP push to wake the app and present the
// CallKit incoming-call UI. Optional; nil means calls only work in-foreground.
type VoIPPusher interface {
	PushVoIP(deviceToken, callID string) error
}

type Hub struct {
	store      *store.Store
	pusher     Pusher
	fcmPusher  FCMPusher
	voipPusher VoIPPusher

	mu       sync.RWMutex
	sessions map[string]Session // key: accountID/deviceID
	// No presence / last-seen is tracked at all: the relay exposes no
	// online-status oracle (it would let anyone with an account id watch a
	// user's activity pattern).

	shares *queueShares   // per-(sender, destination) queue occupancy
	pushes *pushCoalescer // per-device push coalescing
}

func New(st *store.Store) *Hub {
	return &Hub{
		store:    st,
		sessions: make(map[string]Session),
		shares:   newQueueShares(maxQueuedPerSender),
		pushes:   newPushCoalescer(pushCoalesceWindow),
	}
}

// Prune drops stale in-memory bookkeeping (queue shares of envelopes that have
// since expired, idle push-coalescing state). relayd calls it hourly.
func (h *Hub) Prune(queueTTL time.Duration) {
	h.shares.prune(queueTTL)
	h.pushes.prune()
}

// tokenInvalid reports whether a push error says the device token is
// permanently dead (the pusher's error implements TokenInvalid() bool).
func tokenInvalid(err error) bool {
	var ti interface{ TokenInvalid() bool }
	return errors.As(err, &ti) && ti.TokenInvalid()
}

// clearDeadToken forgets a token the provider rejected as permanently invalid.
func (h *Hub) clearDeadToken(accountID string, deviceID uint32, kind, token string) {
	if err := h.store.ClearPushToken(accountID, deviceID, kind, token); err != nil {
		slog.Warn("push: clearing invalid token failed", "err", privlog.Error(err))
	} else {
		slog.Debug("push: cleared invalid token", "kind", kind)
	}
}

// SetPusher attaches an APNs sender used to wake offline devices.
func (h *Hub) SetPusher(p Pusher) { h.pusher = p }

// SetFCMPusher attaches a Firebase Cloud Messaging sender for Android devices.
func (h *Hub) SetFCMPusher(p FCMPusher) { h.fcmPusher = p }

// SetVoIPPusher attaches a PushKit sender for incoming-call wakes.
func (h *Hub) SetVoIPPusher(p VoIPPusher) { h.voipPusher = p }

// PushCallToAccount wakes every device of accountID for an incoming call,
// using the transport each device registered, as Deliver does. iOS ('apns')
// gets a PushKit VoIP push to its separate VoIP token; Android ('fcm') gets a
// high-priority FCM data message. The push carries only the call id, never who
// is calling: the caller's identity and call kind reach the callee only inside
// the end-to-end-encrypted call offer.
func (h *Hub) PushCallToAccount(accountID, callID string) {
	devices, err := h.store.ListDevices(accountID)
	if err != nil {
		slog.Warn("call push: device lookup failed", "err", privlog.Error(err))
		return
	}
	for _, d := range devices {
		transport, token, err := h.store.PushTarget(accountID, d.DeviceID)
		if err != nil {
			slog.Warn("call push: push target lookup failed", "err", privlog.Error(err))
			continue
		}
		switch transport {
		case "fcm":
			if h.fcmPusher == nil || token == "" {
				continue
			}
			t := token
			devID := d.DeviceID
			go func() {
				if err := h.fcmPusher.PushCall(t, callID); err != nil {
					slog.Warn("call push (fcm) failed", "err", privlog.Error(err))
					if tokenInvalid(err) {
						h.clearDeadToken(accountID, devID, store.PushTokenFCM, t)
					}
				} else {
					slog.Debug("call push sent", "kind", "fcm")
				}
			}()
		default: // apns; PushKit uses the device's separate VoIP token
			if h.voipPusher == nil {
				continue
			}
			voipToken, err := h.store.VoIPToken(accountID, d.DeviceID)
			if err != nil || voipToken == "" {
				continue
			}
			t := voipToken
			devID := d.DeviceID
			go func() {
				if err := h.voipPusher.PushVoIP(t, callID); err != nil {
					slog.Warn("call push (voip) failed", "err", privlog.Error(err))
					if tokenInvalid(err) {
						h.clearDeadToken(accountID, devID, store.PushTokenVoIP, t)
					}
				} else {
					slog.Debug("call push sent", "kind", "voip")
				}
			}()
		}
	}
}

func key(accountID string, deviceID uint32) string {
	return fmt.Sprintf("%s/%d", accountID, deviceID)
}

// Register attaches a live session for the device. If the device already had
// a live session (a reconnect racing the old socket's timeout, or a second
// connection with the same credentials), the previous one is closed so there
// is exactly one socket per device. The caller then drains the offline queue
// (in pages, from the store) and sends QueueEmpty.
func (h *Hub) Register(accountID string, deviceID uint32, s Session) {
	k := key(accountID, deviceID)
	h.mu.Lock()
	prev := h.sessions[k]
	h.sessions[k] = s
	h.mu.Unlock()
	if prev != nil && prev != s {
		// Outside the lock: closing runs the old session's Unregister, which
		// is a no-op because the map points at the new session.
		if c, ok := prev.(Closer); ok {
			c.Close("replaced by a newer connection")
		}
	}
	slog.Debug("ws: session registered")
}

// Unregister detaches a session if it is still the current one for the
// device (a reconnect may already have replaced it).
func (h *Hub) Unregister(accountID string, deviceID uint32, s Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	k := key(accountID, deviceID)
	if h.sessions[k] == s {
		delete(h.sessions, k)
		slog.Debug("ws: session unregistered")
	}
}

// Closer is optionally implemented by a Session that can be forcibly torn down
// by the server (e.g. on account deletion). Closing must be safe to call from
// any goroutine and must cause the session's read loop to exit, which then
// runs the normal Unregister cleanup.
type Closer interface {
	Close(reason string)
}

// DisconnectAccount detaches and closes every live session of an account and
// forgets its in-memory presence. Used when the account is deleted so no
// already-authenticated WebSocket outlives it. Returns how many sessions were
// closed.
func (h *Hub) DisconnectAccount(accountID string, reason string) int {
	prefix := accountID + "/"
	var victims []Session
	h.mu.Lock()
	for k, s := range h.sessions {
		if strings.HasPrefix(k, prefix) {
			victims = append(victims, s)
			delete(h.sessions, k)
		}
	}
	h.mu.Unlock()
	// Close outside the lock: closing triggers the session's own Unregister,
	// which takes h.mu (a no-op, since the entry is already gone).
	for _, s := range victims {
		if c, ok := s.(Closer); ok {
			c.Close(reason)
		}
	}
	h.shares.releaseWhere(func(d string) bool { return strings.HasPrefix(d, prefix) })
	if len(victims) > 0 {
		slog.Debug("ws: account sessions disconnected", "count", len(victims))
	}
	return len(victims)
}

// DisconnectDevice detaches and closes one device's live session (if any) and
// forgets its queue-share bookkeeping. Used when the device is removed from its
// account so an already-authenticated socket can't outlive it. Reports whether
// a session was closed.
func (h *Hub) DisconnectDevice(accountID string, deviceID uint32, reason string) bool {
	k := key(accountID, deviceID)
	h.mu.Lock()
	s := h.sessions[k]
	delete(h.sessions, k)
	h.mu.Unlock()
	h.shares.releaseWhere(func(d string) bool { return d == k })
	if s == nil {
		return false
	}
	if c, ok := s.(Closer); ok {
		c.Close(reason)
	}
	return true
}

// Deliver routes one envelope to one device without per-sender queue
// accounting. Prefer DeliverFrom.
func (h *Hub) Deliver(accountID string, deviceID uint32, env *relaypb.Envelope) error {
	return h.DeliverFrom("", accountID, deviceID, env, true)
}

// DeliverFrom routes one envelope to one device. Non-ephemeral envelopes are
// queued first so a crash between here and the socket write loses nothing.
//
// sender identifies who is sending for queue fairness: an authenticated
// account id, or a source-IP bucket for sealed sends ("" is unaccounted). It is
// only ever used hashed. If that sender already holds maxQueuedPerSender
// unacked envelopes in this device's queue, ErrSenderQuota is returned and
// nothing is queued or pushed.
//
// push=false (silent sends such as receipts) queues without waking an offline
// device; it gets the envelope the next time it connects.
func (h *Hub) DeliverFrom(sender, accountID string, deviceID uint32, env *relaypb.Envelope, push bool) error {
	frame := &relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Envelope{Envelope: env}}
	devKey := key(accountID, deviceID)

	var blob []byte
	if !env.Ephemeral {
		var err error
		blob, err = proto.Marshal(env)
		if err != nil {
			return err
		}
		reserved := false
		if sender != "" {
			if !h.shares.reserve(limitkey.Hash("queue-share", sender, devKey), devKey, env.Id) {
				return ErrSenderQuota
			}
			reserved = true
		}
		if err := h.store.Enqueue(env.Id, accountID, deviceID, blob); err != nil {
			if reserved {
				h.shares.release(devKey, env.Id)
			}
			return err
		}
	}

	h.mu.RLock()
	s := h.sessions[key(accountID, deviceID)]
	h.mu.RUnlock()
	if s != nil {
		if !s.Send(frame) {
			// Socket is full or already gone (close frame not yet processed).
			// The envelope is already queued; push as well so the device wakes
			// now instead of after the 60s pong timeout and a reconnect.
			slog.Debug("hub: session backlogged, also pushing")
			if !env.Ephemeral && push {
				h.notifyOffline(accountID, deviceID, env, blob)
			}
		}
		return nil
	}

	// Offline: wake the device (APNs/FCM) so it fetches the envelope.
	if !env.Ephemeral && push {
		h.notifyOffline(accountID, deviceID, env, blob)
	}
	return nil
}

func (h *Hub) notifyOffline(accountID string, deviceID uint32, env *relaypb.Envelope, envelope []byte) {
	if h.pusher == nil && h.fcmPusher == nil {
		return
	}
	kind, token, err := h.store.PushTarget(accountID, deviceID)
	if err != nil || token == "" {
		if err != nil {
			slog.Warn("push: token lookup failed", "err", privlog.Error(err))
		} else {
			slog.Debug("push: offline device has no token")
		}
		return
	}

	// Pick the transport registered by this device. If its sender isn't
	// configured on this server, the envelope still delivers on next connect.
	var send func(string, []byte) error
	switch kind {
	case "fcm":
		if h.fcmPusher == nil {
			slog.Debug("push: fcm device but no fcm sender configured")
			return
		}
		send = h.fcmPusher.Push
	default:
		if h.pusher == nil {
			return
		}
		send = h.pusher.Push
	}

	// Content-free wake by default: the device fetches and decrypts the envelope
	// from the relay, so the push provider never carries message data. A device
	// may opt in to ciphertext-in-push (faster) via its push-content preference.
	//
	// Only a sealed envelope (no sender fields) is ever embedded: the push
	// provider must not learn who messaged whom. Stripping the sender from an
	// authenticated-path envelope would leave the recipient unable to decrypt
	// it from the payload, so such envelopes get a content-free wake instead
	// and are fetched from the queue like the default mode.
	payload := []byte(nil)
	if include, err := h.store.PushIncludeContent(accountID, deviceID); err != nil {
		slog.Warn("push: push-content lookup failed", "err", privlog.Error(err))
	} else if include && env.SenderAccount == "" && env.SenderDevice == 0 {
		payload = envelope
	}
	tokenKind := store.PushTokenAPNs
	if kind == "fcm" {
		tokenKind = store.PushTokenFCM
	}
	slog.Debug("push: waking offline device", "kind", kind)
	// Coalesce bursts: at most one push per device per pushCoalesceWindow,
	// plus one trailing push so the newest message always gets a wake.
	h.pushes.submit(key(accountID, deviceID), func() {
		if err := send(token, payload); err != nil {
			slog.Warn("push failed", "kind", kind, "err", privlog.Error(err))
			if tokenInvalid(err) {
				h.clearDeadToken(accountID, deviceID, tokenKind, token)
			}
		} else {
			slog.Debug("push sent", "kind", kind)
		}
	})
}

// BroadcastNuke sends a NukeCommand frame to every live session of the account.
// Connected devices self-destruct immediately; offline devices receive it on reconnect.
func (h *Hub) BroadcastNuke(accountID string, nuke *relaypb.NukeCommand) {
	frame := &relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Nuke{Nuke: nuke}}
	h.broadcastToAccount(accountID, frame)
	// StoreNuke purged the account's queues; forget their share bookkeeping.
	prefix := accountID + "/"
	h.shares.releaseWhere(func(d string) bool { return strings.HasPrefix(d, prefix) })
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

// AccountSession is one live session of an account.
type AccountSession struct {
	DeviceID uint32
	Session  Session
}

// AccountSessions returns the account's live sessions (a snapshot).
func (h *Hub) AccountSessions(accountID string) []AccountSession {
	h.mu.RLock()
	defer h.mu.RUnlock()
	prefix := accountID + "/"
	var out []AccountSession
	for k, s := range h.sessions {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		id, err := strconv.ParseUint(strings.TrimPrefix(k, prefix), 10, 32)
		if err != nil {
			continue
		}
		out = append(out, AccountSession{DeviceID: uint32(id), Session: s})
	}
	return out
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

// Ack removes a delivered envelope from the device's queue and frees the
// sender's queue share.
func (h *Hub) Ack(accountID string, deviceID uint32, envelopeID string) error {
	if err := h.store.Dequeue(envelopeID, accountID, deviceID); err != nil {
		return err
	}
	h.shares.release(key(accountID, deviceID), envelopeID)
	return nil
}
