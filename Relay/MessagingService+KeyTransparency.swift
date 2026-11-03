//
//  MessagingService+KeyTransparency.swift
//  Relay
//
//  Checks contacts' identity keys against the relay's key directory, keeps the
//  directory's history honest (each new head must extend the last one we saw),
//  and watches our own account for keys this device didn't make. See
//  docs/KEY_TRANSPARENCY.md.
//

import Foundation
import RelayKit
import SecureStorage

extension MessagingService {
    enum TransparencyStatus: Equatable {
        /// The key we use for them is the one the directory publishes.
        case verified
        /// The directory lists a different key: someone may be intercepting.
        case mismatch
        /// Couldn't check (offline, or nothing published yet).
        case unavailable
    }

    private static let headKey = "kt.head"
    private static let monitorAtKey = "kt.monitor.at"
    private static let monitorBaselineKey = "kt.monitor.baseline"
    private static let historyAlarmKey = "kt.history.alarmed"
    private static let witnessAtKey = "kt.witness.at"

    /// The identity key the safety number is computed from: the newest device's.
    private func currentIdentityKey(of peer: String) -> Data? {
        guard let deviceId = try? storage.signalStore.newestIdentityDeviceId(address: peer) else { return nil }
        return (try? storage.database.query(
            "SELECT identity_key FROM remote_identities WHERE address = ? AND device_id = ?",
            [.text(peer), .integer(Int64(deviceId))]
        ).first?.first?.data) ?? nil
    }

    /// Checks `peer`'s key against the directory and records the result. A key
    /// changed in the last minute may not be published yet, so a mismatch is
    /// checked again before it counts.
    @discardableResult
    func refreshTransparency(peer: String) async -> TransparencyStatus {
        guard peer != credentials.accountId, peer != Self.relayOfficialAccount,
              let key = currentIdentityKey(of: peer)
        else { return .unavailable }
        var status = await lookUp(peer: peer, key: key)
        if status == .mismatch {
            try? await Task.sleep(for: .seconds(75))
            if currentIdentityKey(of: peer) == key { status = await lookUp(peer: peer, key: key) }
        }
        if keyTransparencyStatus[peer] != status {
            keyTransparencyStatus[peer] = status
            refreshConversations()
        }
        return status
    }

    private func lookUp(peer: String, key: Data) async -> TransparencyStatus {
        do {
            let lookup = try await apiClient.keyTransparencyLookup(account: peer)
            guard await acceptHead(lookup.head) else { return .mismatch }
            try KeyTransparency.verify(lookup, account: peer, key: key)
            return .verified
        } catch is KeyTransparency.Failure {
            return .mismatch
        } catch {
            return .unavailable
        }
    }

    // MARK: Heads

    private func storedHead() -> KeyTransparency.Head? {
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(Self.headKey)]).first?.first?.data) ?? nil
        else { return nil }
        return try? JSONDecoder().decode(KeyTransparency.Head.self, from: data)
    }

    private func store(head: KeyTransparency.Head) {
        guard let data = try? JSONEncoder().encode(head) else { return }
        try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                  [.text(Self.headKey), .blob(data)])
    }

    /// A head is acceptable if it's signed and its log extends (or is extended
    /// by) the last head this device saw. Remembers the newest.
    func acceptHead(_ head: KeyTransparency.Head) async -> Bool {
        guard KeyTransparency.verifySignature(head) else { return false }
        guard let last = storedHead() else {
            store(head: head)
            return true
        }
        if head.logSize == last.logSize { return head.logRoot == last.logRoot }
        let (old, new) = head.logSize > last.logSize ? (last, head) : (head, last)
        guard let proof = try? await apiClient.keyTransparencyConsistency(from: old.logSize, to: new.logSize) else {
            return false
        }
        guard KeyTransparency.verifyConsistency(old: old, new: new, proof: proof) else {
            alarmHistory()
            return false
        }
        if head.logSize > last.logSize { store(head: head) }
        return true
    }

    /// The relay showed a directory whose history doesn't match what it showed
    /// before: tell the user once.
    private func alarmHistory() {
        guard readKVFlag(Self.historyAlarmKey) == false else { return }
        writeKVFlag(Self.historyAlarmKey)
        postRelayNotice("Relay's public record of keys showed this iPhone a history that doesn't match what it showed before or what everyone else sees. Someone may be trying to show you fake keys. Compare safety numbers in person with anyone you need to trust before sharing anything sensitive.")
    }

    // MARK: Witness

    /// About hourly: the head published outside Relay's servers must be part of
    /// the same history this device was shown. If the relay showed us a
    /// different directory from everyone else, the two can't be reconciled.
    func checkWitnessIfDue() async {
        let now = Int64(Date().timeIntervalSince1970)
        guard now - readKVTimestamp(Self.witnessAtKey) > 3600 else { return }
        guard let witness = await KeyTransparency.fetchWitnessHead() else { return }
        // A failed consistency check raises the alarm inside acceptHead.
        if await acceptHead(witness) {
            writeKVTimestamp(Self.witnessAtKey, now)
        }
    }

    // MARK: Watching our own account

    /// Every few hours: our account's history holds only keys this device's
    /// account made. The first check takes the history as it is.
    func monitorOwnKeysIfDue() async {
        let now = Int64(Date().timeIntervalSince1970)
        guard now - readKVTimestamp(Self.monitorAtKey) > 6 * 3600 else { return }
        guard let own = ownIdentityKey(),
              let (versions, latest) = try? await apiClient.keyTransparencyMonitor(),
              let last = versions.last
        else { return }
        guard await acceptHead(latest.head) else { return }
        let full = KeyTransparency.Lookup(
            vrfProof: latest.vrfProof, version: latest.version, commitment: latest.commitment,
            prevChain: latest.prevChain, nonce: last.nonce, keys: last.keys, proof: latest.proof, head: latest.head)
        guard (try? KeyTransparency.verify(full, account: credentials.accountId, key: own)) != nil,
              let sets = try? KeyTransparency.verifyHistory(versions, latest: full)
        else {
            // Not published yet right after sign-up; checked again next time.
            return
        }
        writeKVTimestamp(Self.monitorAtKey, now)
        var baseline = readKVTimestamp(Self.monitorBaselineKey)
        if baseline == 0 {
            baseline = Int64(latest.version)
            writeKVTimestamp(Self.monitorBaselineKey, baseline)
        }
        for (index, keys) in sets.enumerated() where Int64(index + 1) > baseline {
            if keys.contains(where: { $0 != own }) {
                let alarmKey = "kt.own.alarmed.\(index + 1)"
                guard !readKVFlag(alarmKey) else { continue }
                writeKVFlag(alarmKey)
                postRelayNotice("Relay's public record of keys listed a key for your account that this iPhone didn't make. If you didn't sign in on a new device around then, someone may have been shown a fake key for you. Ask your contacts to compare safety numbers with you.")
            }
        }
    }

    // MARK: kv

    private func readKVTimestamp(_ key: String) -> Int64 {
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.first?.data) ?? nil,
              let value = Int64(String(decoding: data, as: UTF8.self))
        else { return 0 }
        return value
    }

    private func writeKVTimestamp(_ key: String, _ value: Int64) {
        try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                  [.text(key), .blob(Data(String(value).utf8))])
    }

    private func readKVFlag(_ key: String) -> Bool { readKVTimestamp(key) != 0 }
    private func writeKVFlag(_ key: String) { writeKVTimestamp(key, 1) }
}
