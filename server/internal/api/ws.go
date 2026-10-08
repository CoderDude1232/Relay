package api

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/privlog"
	"github.com/relayapp/relay-server/internal/store"
	"google.golang.org/protobuf/proto"
)

const (
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = 45 * time.Second
	maxFrameSize   = 512 * 1024 // generous for text; media moves over HTTP later
	sendBufferSize = 256
)

// Offline-queue paging, shared by the WebSocket drain and GET /v1/queue: a
// page holds at most queuePageMaxEnvelopes envelopes and stops early once it
// reaches queuePageMaxBytes of ciphertext, so neither path ever loads a whole
// (up to 50 MB) queue into memory.
const (
	queuePageMaxEnvelopes = 100
	queuePageMaxBytes     = 4 << 20
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// Auth is a Relay-Sig signature on the upgrade request; browser clients are not a
	// target, so cross-origin checks are irrelevant here.
	CheckOrigin: func(*http.Request) bool { return true },
}

// wsSession implements hub.Session over one WebSocket connection.
type wsSession struct {
	conn *websocket.Conn
	out  chan *relaypb.ServerFrame
	done chan struct{}
	// writerDone is closed when writePump exits (write error / timeout), so a
	// blocked sendBlocking can't wait forever on a dead connection.
	writerDone chan struct{}
}

func (s *wsSession) Send(frame *relaypb.ServerFrame) bool {
	select {
	case s.out <- frame:
		return true
	case <-s.done:
		return false
	default:
		return false // buffer full; queued envelopes survive in the store
	}
}

// sendBlocking enqueues a frame for the writer, waiting for buffer space
// instead of dropping it. Used by the session's own goroutine (queue drain,
// QueueEmpty, SendResponses) so a slow reader gets backpressure rather than
// silently lost frames. Returns false once the connection is gone.
func (s *wsSession) sendBlocking(frame *relaypb.ServerFrame) bool {
	select {
	case s.out <- frame:
		return true
	case <-s.done:
		return false
	case <-s.writerDone:
		return false
	}
}

// Close forcibly tears the connection down (hub.Closer), e.g. when the account
// is deleted. It sends a best-effort close frame, then closes the socket; the
// read loop errors out and runs the normal Unregister cleanup. WriteControl and
// Close are safe to call concurrently with the read/write pumps.
func (s *wsSession) Close(reason string) {
	msg := websocket.FormatCloseMessage(websocket.ClosePolicyViolation, reason)
	s.conn.WriteControl(websocket.CloseMessage, msg, time.Now().Add(time.Second)) //nolint:errcheck
	s.conn.Close()
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return // Upgrade already wrote the error response
	}
	sess := &wsSession{
		conn:       conn,
		out:        make(chan *relaypb.ServerFrame, sendBufferSize),
		done:       make(chan struct{}),
		writerDone: make(chan struct{}),
	}

	s.hub.Register(dev.AccountID, dev.DeviceID, sess)
	defer func() {
		s.hub.Unregister(dev.AccountID, dev.DeviceID, sess)
		close(sess.done)
		conn.Close()
	}()

	// Close the race with DELETE /v1/accounts/me: if the account was deleted
	// between auth and Register, DisconnectAccount missed this session.
	if _, err := s.store.DeviceByID(dev.AccountID, dev.DeviceID); err != nil {
		return
	}

	go sess.writePump()

	// If a nuke was issued while this device was offline, deliver it directly
	// and then close — the client will wipe itself and there is nothing left to
	// drain. We write directly to the connection instead of going through the
	// buffered channel so the frame is guaranteed to be sent before the deferred
	// cleanup fires (close(sess.done) could race with writePump draining the
	// channel and cause the nuke frame to be silently dropped).
	if pending, err := s.store.PendingNukeForAccount(dev.AccountID); err != nil {
		slog.Error("ws: pending nuke check failed", "err", privlog.Error(err))
	} else if pending != nil && nukeIsStale(pending.CreationTimeMs) {
		// The nuke is older than the client's freshness window, so the client
		// would reject it. Delivering (and closing) it on every reconnect would
		// wedge the account permanently offline. Purge it and connect normally.
		if err := s.store.DeleteNukesForAccount(dev.AccountID); err != nil {
			slog.Error("ws: stale nuke purge failed", "err", privlog.Error(err))
		}
	} else if pending != nil {
		nukeFrame := &relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Nuke{
			Nuke: &relaypb.NukeCommand{
				AccountId:          pending.AccountID,
				CommandId:          pending.CommandID,
				CreationTimeMs:     pending.CreationTimeMs,
				InitiatingDeviceId: pending.InitiatingDeviceID,
				Signature:          pending.Signature,
			},
		}}
		if data, err := proto.Marshal(nukeFrame); err == nil {
			conn.SetWriteDeadline(time.Now().Add(writeWait))
			conn.WriteMessage(websocket.BinaryMessage, data) //nolint:errcheck
		}
		return
	}

	// Drain the offline queue page by page, then mark it empty. These go
	// through the same buffered channel as live traffic to keep ordering, but
	// with backpressure (sendBlocking): nothing is dropped when the buffer is
	// full, and only one page is held in memory at a time.
	if !s.drainQueue(dev, sess) {
		return
	}
	if !sess.sendBlocking(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_QueueEmpty{QueueEmpty: &relaypb.QueueEmpty{}}}) {
		return
	}

	// Read loop.
	conn.SetReadLimit(maxFrameSize)
	conn.SetReadDeadline(time.Now().Add(pongWait))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(pongWait))
	})
	for {
		msgType, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if msgType != websocket.BinaryMessage {
			continue
		}
		frame := &relaypb.ClientFrame{}
		if err := proto.Unmarshal(data, frame); err != nil {
			slog.Warn("ws: unparseable client frame")
			continue
		}
		switch p := frame.Payload.(type) {
		case *relaypb.ClientFrame_Send:
			var resp *relaypb.SendResponse
			if wsSendLimiter.allow(dev.AccountID) {
				resp = s.handleSend(dev, p.Send)
			} else {
				resp = &relaypb.SendResponse{
					Status:          relaypb.SendStatus_SEND_STATUS_RATE_LIMITED,
					ServerTimestamp: time.Now().UnixMilli(),
				}
			}
			resp.ReplyTo = frame.Id
			if !sess.sendBlocking(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_SendResponse{SendResponse: resp}}) {
				return
			}
		case *relaypb.ClientFrame_Ack:
			if err := s.hub.Ack(dev.AccountID, dev.DeviceID, p.Ack.EnvelopeId); err != nil {
				slog.Error("ws: ack failed", "err", privlog.Error(err))
			}
		}
	}
}

// drainQueue streams the device's offline queue to the session in pages.
// Returns false if the connection went away (or the store failed) mid-drain.
func (s *Server) drainQueue(dev *store.Device, sess *wsSession) bool {
	var cursor store.QueueCursor
	for {
		page, more, err := s.store.QueuedEnvelopesPage(dev.AccountID, dev.DeviceID, cursor, queuePageMaxEnvelopes, queuePageMaxBytes)
		if err != nil {
			slog.Error("ws: queue drain failed", "err", privlog.Error(err))
			return false
		}
		for _, q := range page {
			cursor = store.QueueCursor{CreatedAt: q.CreatedAt, EnvelopeID: q.ID}
			env := &relaypb.Envelope{}
			if err := proto.Unmarshal(q.Envelope, env); err != nil {
				slog.Error("ws: corrupt queued envelope dropped", "err", privlog.Error(err))
				continue
			}
			if !sess.sendBlocking(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Envelope{Envelope: env}}) {
				return false
			}
		}
		if !more {
			return true
		}
	}
}

func (sess *wsSession) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
	// On a write failure, tear the socket down so the read loop (and any
	// blocked sendBlocking) unwinds instead of waiting on a dead writer.
	defer func() {
		close(sess.writerDone)
		sess.conn.Close()
	}()
	for {
		select {
		case frame := <-sess.out:
			data, err := proto.Marshal(frame)
			if err != nil {
				slog.Error("ws: marshal failed", "err", privlog.Error(err))
				continue
			}
			sess.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := sess.conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
				return
			}
		case <-ticker.C:
			sess.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := sess.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		case <-sess.done:
			return
		}
	}
}

// handleSend routes one encrypted payload to one opaque device mailbox. New
// clients no longer send destination account IDs on this path; the protobuf
// field is kept for wire compatibility but now contains a mailbox ID.
func (s *Server) handleSend(sender *store.Device, req *relaypb.SendRequest) *relaypb.SendResponse {
	now := time.Now().UnixMilli()
	resp := &relaypb.SendResponse{ServerTimestamp: now}

	if len(req.Messages) != 1 {
		resp.Status = relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES
		return resp
	}

	destination, err := s.store.DeviceByMailbox(req.DestinationAccount)
	if err != nil {
		if err == store.ErrNotFound {
			resp.Status = relaypb.SendStatus_SEND_STATUS_UNKNOWN_ACCOUNT
		} else {
			slog.Error("send: mailbox lookup failed", "err", privlog.Error(err))
			resp.Status = relaypb.SendStatus_SEND_STATUS_UNSPECIFIED
		}
		return resp
	}

	m := req.Messages[0]
	if m.DeviceId != destination.DeviceID {
		resp.ExtraDevices = append(resp.ExtraDevices, m.DeviceId)
		resp.Status = relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES
		return resp
	}
	if m.RegistrationId != 0 && m.RegistrationId != destination.RegistrationID {
		resp.StaleDevices = append(resp.StaleDevices, m.DeviceId)
		resp.Status = relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES
		return resp
	}

	env := &relaypb.Envelope{
		Id:              newEnvelopeID(),
		SenderAccount:   sender.AccountID,
		SenderDevice:    sender.DeviceID,
		Type:            m.Type,
		Content:         m.Content,
		ClientTimestamp: req.ClientTimestamp,
		ServerTimestamp: now,
		Ephemeral:       req.Ephemeral,
	}
	if err := s.hub.DeliverFrom(sender.AccountID, destination.AccountID, destination.DeviceID, env); err != nil {
		if errors.Is(err, hub.ErrSenderQuota) || errors.Is(err, store.ErrQueueFull) {
			// This sender's share of the recipient's queue (or the whole
			// queue) is full; retry later.
			resp.Status = relaypb.SendStatus_SEND_STATUS_RATE_LIMITED
			return resp
		}
		if errors.Is(err, store.ErrNotFound) {
			// The device was removed between the mailbox lookup and enqueue.
			resp.Status = relaypb.SendStatus_SEND_STATUS_UNKNOWN_ACCOUNT
			return resp
		}
		slog.Error("send: deliver failed", "err", privlog.Error(err))
		resp.Status = relaypb.SendStatus_SEND_STATUS_UNSPECIFIED
		return resp
	}
	resp.Status = relaypb.SendStatus_SEND_STATUS_OK

	// Cross-account send: tell the sender about other registered devices it
	// didn't address. The message above was already delivered; the sender
	// should send to the missing devices without re-sending to this one.
	// Skip this for self-sends (own-device sync) so the phone doesn't get
	// asked to re-send its own sync messages to itself.
	if !req.Ephemeral && sender.AccountID != destination.AccountID {
		all, err := s.store.Devices(destination.AccountID)
		if err == nil {
			for _, d := range all {
				if d.DeviceID != destination.DeviceID {
					resp.MissingDevices = append(resp.MissingDevices, d.DeviceID)
				}
			}
			if len(resp.MissingDevices) > 0 {
				resp.Status = relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES
			}
		}
	}
	return resp
}

// nukeIsStale reports whether a stored nuke command is older than the client's
// 5-minute freshness window. Such a nuke would be rejected on delivery, so the
// server purges it instead of delivering (and closing) on every reconnect.
func nukeIsStale(creationTimeMs int64) bool {
	return time.Now().UnixMilli()-creationTimeMs > 5*60*1000
}

func newEnvelopeID() string {
	var b [16]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
