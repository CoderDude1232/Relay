package api

import (
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
	"github.com/relayapp/relay-server/gen/relaypb"
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

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// Auth is HTTP Basic on the upgrade request; browser clients are not a
	// target, so cross-origin checks are irrelevant here.
	CheckOrigin: func(*http.Request) bool { return true },
}

// wsSession implements hub.Session over one WebSocket connection.
type wsSession struct {
	conn *websocket.Conn
	out  chan *relaypb.ServerFrame
	done chan struct{}
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

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return // Upgrade already wrote the error response
	}
	sess := &wsSession{
		conn: conn,
		out:  make(chan *relaypb.ServerFrame, sendBufferSize),
		done: make(chan struct{}),
	}

	queued, err := s.hub.Register(dev.AccountID, dev.DeviceID, sess)
	if err != nil {
		slog.Error("ws: queue drain failed", "err", privlog.Error(err))
		conn.Close()
		return
	}
	defer func() {
		s.hub.Unregister(dev.AccountID, dev.DeviceID, sess)
		close(sess.done)
		conn.Close()
	}()

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

	// Drain the offline queue, then mark it empty. These go through the
	// same buffered channel as live traffic to keep ordering.
	for _, blob := range queued {
		env := &relaypb.Envelope{}
		if err := proto.Unmarshal(blob, env); err != nil {
			slog.Error("ws: corrupt queued envelope dropped", "err", privlog.Error(err))
			continue
		}
		sess.Send(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_Envelope{Envelope: env}})
	}
	sess.Send(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_QueueEmpty{QueueEmpty: &relaypb.QueueEmpty{}}})

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
			resp := s.handleSend(dev, p.Send)
			resp.ReplyTo = frame.Id
			sess.Send(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_SendResponse{SendResponse: resp}})
		case *relaypb.ClientFrame_Ack:
			if err := s.hub.Ack(dev.AccountID, dev.DeviceID, p.Ack.EnvelopeId); err != nil {
				slog.Error("ws: ack failed", "err", privlog.Error(err))
			}
		}
	}
}

func (sess *wsSession) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
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
	if err := s.hub.Deliver(destination.AccountID, destination.DeviceID, env); err != nil {
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
