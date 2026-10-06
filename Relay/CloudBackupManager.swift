//
//  CloudBackupManager.swift
//  Relay
//
//  Signal-style end-to-end-encrypted iCloud backup. A snapshot of local chat
//  state is encrypted on-device with a key derived from a user-held Recovery
//  Key, then stored as an opaque blob in the app's CloudKit private database.
//  Apple (and Relay) only ever see ciphertext — losing the Recovery Key means
//  the backup is unrecoverable, by design.
//
//  The Recovery Key is 32 random bytes shown to the user as a grouped hex
//  string to write down. It's cached in this device's Keychain so backups keep
//  running automatically; on a new device the user re-enters it to restore.
//
//  NOTE: encryption sessions are Secure-Enclave-bound and are NOT part of the
//  backup — restoring brings back message history; sessions re-key on next
//  contact (a safety-number change, like a Signal reinstall).
//

import CloudKit
import CryptoKit
import Foundation
import Observation
import RelayKit
import Security

@Observable
@MainActor
final class CloudBackupManager {
    static let shared = CloudBackupManager()

    enum Status: Equatable {
        case idle
        case working
        case success(Date)
        case failed(String)
    }

    private(set) var status: Status = .idle

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { ensureRecoveryKey() }
        }
    }

    var lastBackup: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.lastBackupKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastBackupKey) }
    }

    private static let enabledKey = "relay.icloudBackup.enabled"
    private static let lastBackupKey = "relay.icloudBackup.lastAt"
    private static let keychainAccount = "relay.icloudBackup.recoveryKey"
    private static let containerId = "iCloud.app.relaymsg"
    private static let recordType = "Backup"

    private var database: CKDatabase {
        CKContainer(identifier: Self.containerId).privateCloudDatabase
    }

    private var debounceTask: Task<Void, Never>?

    // MARK: - Recovery key

    /// The current recovery key formatted for display (grouped hex), or nil if none.
    var recoveryKeyDisplay: String? {
        recoveryKeyData().map { Self.format($0) }
    }

    /// Generates and persists a recovery key if one doesn't exist yet.
    @discardableResult
    func ensureRecoveryKey() -> String {
        if let existing = recoveryKeyData() { return Self.format(existing) }
        var bytes = Data(count: 32)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        storeRecoveryKey(bytes)
        return Self.format(bytes)
    }

    private func backupKey(from recoveryKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoveryKey),
            salt: Data("relay-icloud-backup".utf8),
            info: Data("v1".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Backup

    /// Encrypts the current snapshot and writes it to CloudKit. Best-effort.
    func backupNow(service: MessagingService) async {
        guard isEnabled else { return }
        status = .working
        do {
            guard try await accountAvailable() else {
                status = .failed("Sign in to iCloud to back up.")
                return
            }
            let key = backupKey(from: recoveryKeyData() ?? {
                let k = Data(hexOrEmpty: ensureRecoveryKey()); return k
            }())
            let snapshot = service.exportBackupSnapshot()
            let plaintext = try JSONEncoder().encode(snapshot)
            let sealed = try AES.GCM.seal(plaintext, using: key).combined!

            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
            try sealed.write(to: tmp, options: .completeFileProtection)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let recordID = CKRecord.ID(recordName: Self.recordName(service.credentials.accountId))
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record["payload"] = CKAsset(fileURL: tmp)
            record["updatedAt"] = Date() as CKRecordValue
            record["format"] = 1 as CKRecordValue

            // .allKeys overwrites the previous snapshot regardless of change tag.
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            lastBackup = Date()
            status = .success(Date())
        } catch {
            status = .failed(Self.friendly(error))
        }
    }

    /// Debounced auto-backup, safe to call after any change / on background.
    func scheduleBackup(service: MessagingService) {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, weak service] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, let service else { return }
            await self.backupNow(service: service)
        }
    }

    // MARK: - Restore

    /// Fetches and imports the backup for `accountId`, decrypting with the
    /// user-entered recovery key. Persists the key locally on success so future
    /// backups continue from this device.
    func restore(recoveryKey display: String, accountId: String, into service: MessagingService) async throws {
        status = .working
        do {
            let recoveryKey = try Self.parse(display)
            guard try await accountAvailable() else {
                throw BackupError.noICloud
            }
            let recordID = CKRecord.ID(recordName: Self.recordName(accountId))
            let record: CKRecord
            do {
                record = try await database.record(for: recordID)
            } catch let ckError as CKError where ckError.code == .unknownItem {
                throw BackupError.noBackupFound
            }
            guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
                  let sealed = try? Data(contentsOf: url) else {
                throw BackupError.noBackupFound
            }
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(box, using: backupKey(from: recoveryKey))
            } catch {
                throw BackupError.wrongRecoveryKey
            }
            let snapshot = try JSONDecoder().decode(MessagingService.BackupSnapshot.self, from: plaintext)
            service.importBackupSnapshot(snapshot)
            storeRecoveryKey(recoveryKey) // keep backing up from here on
            isEnabled = true
            lastBackup = (record["updatedAt"] as? Date) ?? Date()
            status = .success(Date())
        } catch {
            status = .failed(Self.friendly(error))
            throw error
        }
    }

    // MARK: - Errors

    enum BackupError: LocalizedError {
        case noICloud, noBackupFound, wrongRecoveryKey, badKey

        var errorDescription: String? {
            switch self {
            case .noICloud: return "Sign in to iCloud to use backups."
            case .noBackupFound: return "No iCloud backup was found for this account."
            case .wrongRecoveryKey: return "That recovery key didn't match the backup."
            case .badKey: return "That doesn't look like a valid recovery key."
            }
        }
    }

    private func accountAvailable() async throws -> Bool {
        try await CKContainer(identifier: Self.containerId).accountStatus() == .available
    }

    private static func recordName(_ accountId: String) -> String { "relay-backup-\(accountId)" }

    private static func friendly(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Keychain

    private func recoveryKeyData() -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
        ]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    private func storeRecoveryKey(_ key: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: - Formatting (grouped hex)

    private static func format(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    private static func parse(_ display: String) throws -> Data {
        let hex = display.filter { $0.isHexDigit }
        guard hex.count == 64 else { throw BackupError.badKey }
        var data = Data(capacity: 32)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { throw BackupError.badKey }
            data.append(byte)
            idx = next
        }
        return data
    }
}

private extension Data {
    init(hexOrEmpty: String) {
        let hex = hexOrEmpty.filter { $0.isHexDigit }
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex, let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[idx..<next], radix: 16) { data.append(byte) }
            idx = next
        }
        self = data
    }
}
