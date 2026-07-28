package api

import (
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
	"github.com/relayapp/relay-server/gen/relaypb"
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
		slog.Error("ws: queue drain failed", "err", err)
		conn.Close()
		return
	}
	defer func() {
		s.hub.Unregister(dev.AccountID, dev.DeviceID, sess)
		close(sess.done)
		conn.Close()
	}()

	go sess.writePump()

	// Drain the offline queue, then mark it empty. These go through the
	// same buffered channel as live traffic to keep ordering.
	for _, blob := range queued {
		env := &relaypb.Envelope{}
		if err := proto.Unmarshal(blob, env); err != nil {
			slog.Error("ws: corrupt queued envelope dropped", "err", err)
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
			slog.Warn("ws: unparseable client frame", "account", dev.AccountID, "device", dev.DeviceID)
			continue
		}
		switch p := frame.Payload.(type) {
		case *relaypb.ClientFrame_Send:
			resp := s.handleSend(dev, p.Send)
			resp.ReplyTo = frame.Id
			sess.Send(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_SendResponse{SendResponse: resp}})
		case *relaypb.ClientFrame_Ack:
			if err := s.hub.Ack(dev.AccountID, dev.DeviceID, p.Ack.EnvelopeId); err != nil {
				slog.Error("ws: ack failed", "err", err)
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
				slog.Error("ws: marshal failed", "err", err)
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

// handleSend validates the per-device fan-out and delivers one envelope per
// destination device. The device list must exactly cover the destination
// account's registered devices (minus the sending device on self-sends),
// with matching registration ids — otherwise the whole send is rejected and
// nothing is delivered, so a partial fan-out can never happen.
func (s *Server) handleSend(sender *store.Device, req *relaypb.SendRequest) *relaypb.SendResponse {
	now := time.Now().UnixMilli()
	resp := &relaypb.SendResponse{ServerTimestamp: now}

	devices, err := s.store.Devices(req.DestinationAccount)
	if err != nil {
		slog.Error("send: device lookup failed", "err", err)
		resp.Status = relaypb.SendStatus_SEND_STATUS_UNSPECIFIED
		return resp
	}
	if len(devices) == 0 {
		resp.Status = relaypb.SendStatus_SEND_STATUS_UNKNOWN_ACCOUNT
		return resp
	}

	selfSend := req.DestinationAccount == sender.AccountID
	expected := make(map[uint32]uint32) // device id -> registration id
	for _, d := range devices {
		if selfSend && d.DeviceID == sender.DeviceID {
			continue
		}
		expected[d.DeviceID] = d.RegistrationID
	}

	provided := make(map[uint32]*relaypb.DeviceMessage, len(req.Messages))
	for _, m := range req.Messages {
		provided[m.DeviceId] = m
	}
	for id, regID := range expected {
		m, ok := provided[id]
		if !ok {
			resp.MissingDevices = append(resp.MissingDevices, id)
			continue
		}
		if m.RegistrationId != 0 && m.RegistrationId != regID {
			resp.StaleDevices = append(resp.StaleDevices, id)
		}
	}
	for id := range provided {
		if _, ok := expected[id]; !ok {
			resp.ExtraDevices = append(resp.ExtraDevices, id)
		}
	}
	if len(resp.MissingDevices)+len(resp.ExtraDevices)+len(resp.StaleDevices) > 0 {
		resp.Status = relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES
		return resp
	}

	for _, m := range req.Messages {
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
		if err := s.hub.Deliver(req.DestinationAccount, m.DeviceId, env); err != nil {
			slog.Error("send: deliver failed", "err", err)
			resp.Status = relaypb.SendStatus_SEND_STATUS_UNSPECIFIED
			return resp
		}
	}
	resp.Status = relaypb.SendStatus_SEND_STATUS_OK
	return resp
}

func newEnvelopeID() string {
	var b [16]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
