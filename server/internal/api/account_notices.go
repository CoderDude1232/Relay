package api

import (
	"log/slog"

	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/privlog"
	"github.com/relayapp/relay-server/internal/store"
)

// noticeAccountChange tells the account's other devices that how it signs in
// changed (see relaypb.AccountNotice): now, to those connected, and at their
// next connection otherwise. A device someone briefly had access to can't
// quietly add a passkey or a password without the owner's devices saying so.
func (s *Server) noticeAccountChange(dev *store.Device, kind string) {
	if err := s.store.AddAccountNotice(dev.AccountID, dev.DeviceID, kind); err != nil {
		slog.Error("account notice: store failed", "err", privlog.Error(err))
		return
	}
	for _, live := range s.hub.AccountSessions(dev.AccountID) {
		if live.DeviceID != dev.DeviceID {
			s.deliverAccountNotices(dev.AccountID, live.DeviceID, live.Session.Send)
		}
	}
}

// deliverAccountNotices sends (and deletes) a device's pending notices.
func (s *Server) deliverAccountNotices(accountID string, deviceID uint32, send func(*relaypb.ServerFrame) bool) {
	notices, err := s.store.TakeAccountNotices(accountID, deviceID)
	if err != nil {
		slog.Error("account notice: take failed", "err", privlog.Error(err))
		return
	}
	for _, n := range notices {
		send(&relaypb.ServerFrame{Payload: &relaypb.ServerFrame_AccountNotice{
			AccountNotice: &relaypb.AccountNotice{Kind: n.Kind, TimeMs: n.TimeMs},
		}})
	}
}
