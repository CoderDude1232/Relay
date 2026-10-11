//
//  IdentityAcknowledgement.swift
//  RelayCore
//
//  The identity keys the user has accepted for each peer, kept in the kv table
//  as "peer-identity-ack:<account>" (a JSON list, or one raw key in the legacy
//  format). Shared by the app and the notification extension.
//

import Foundation
import SecureStorage

public enum IdentityAcknowledgement {
    public static func key(forPeer peer: String) -> String {
        "peer-identity-ack:\(peer)"
    }

    /// The acknowledged keys, or nil before first contact.
    public static func acknowledged(forPeer peer: String, storage: SecureStore) throws -> Set<Data>? {
        guard let stored = try storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key(forPeer: peer))]
        ).first?.first?.data else { return nil }
        if let keys = try? JSONDecoder().decode([Data].self, from: stored) {
            return Set(keys)
        }
        return [stored]
    }

    /// False while any stored key for the peer is one the user hasn't accepted
    /// (a changed key, or a device that appeared with a new key). True before
    /// first contact: nothing has been accepted yet, so nothing has changed.
    public static func isSettled(peer: String, storage: SecureStore) -> Bool {
        guard let current = try? Set(storage.signalStore.identityKeys(address: peer)), !current.isEmpty,
              let acknowledged = try? acknowledged(forPeer: peer, storage: storage)
        else { return true }
        return current.isSubset(of: acknowledged)
    }
}
