//
//  BackupView.swift
//  Relay
//
//  Exports an encrypted JSON backup of all conversations + messages
//  to the Files app (or any share destination). The export is
//  encrypted with a one-time password the user sets.
//

import Clibsodium
import CryptoKit
import RelayKit
import SecureStorage
import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    let service: MessagingService

    @State private var backup = CloudBackupManager.shared
    @State private var showRecoveryKey = false
    @State private var showRestoreSheet = false

    @State private var password = ""
    @State private var confirm = ""
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportItem: BackupDocument?
    @State private var showingExporter = false

    private var canExport: Bool {
        password.count >= 8 && password == confirm
    }

    private var iCloudFooter: String {
        var base = "Messages are encrypted with your Recovery Key before leaving your device — Apple can't read them, and losing the key means losing the backup."
        switch backup.status {
        case .working: base += "\n\nBacking up…"
        case .failed(let msg): base += "\n\n⚠️ \(msg)"
        default:
            if let last = backup.lastBackup {
                base += "\n\nLast backup: \(last.formatted(date: .abbreviated, time: .shortened))"
            }
        }
        return base
    }

    var body: some View {
        List {
            // MARK: iCloud backup
            Section {
                Toggle(isOn: Binding(
                    get: { backup.isEnabled },
                    set: { on in
                        backup.isEnabled = on
                        if on {
                            showRecoveryKey = true
                            Task { await backup.backupNow(service: service) }
                        }
                    }
                )) {
                    Label("Back Up to iCloud", systemImage: "icloud.fill")
                }

                if backup.isEnabled {
                    Button {
                        showRecoveryKey = true
                    } label: {
                        Label("View Recovery Key", systemImage: "key.fill")
                    }

                    Button {
                        Task { await backup.backupNow(service: service) }
                    } label: {
                        HStack {
                            Label("Back Up Now", systemImage: "arrow.clockwise.icloud")
                            Spacer()
                            if case .working = backup.status { ProgressView() }
                        }
                    }
                }
            } header: {
                Text("iCloud Backup")
            } footer: {
                Text(iCloudFooter)
            }

            // MARK: Restore
            Section {
                Button {
                    showRestoreSheet = true
                } label: {
                    Label("Restore from iCloud", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Restores messages from your latest iCloud backup using your Recovery Key. Existing messages are kept.")
            }

            // MARK: Manual export
            Section {
                SecureField("Password (min 8 characters)", text: $password)
                SecureField("Confirm password", text: $confirm)
                Button {
                    Task { await export() }
                } label: {
                    HStack {
                        Label("Export Archive (Read-Only)", systemImage: "arrow.up.doc.fill")
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                }
                .disabled(!canExport || isExporting)
            } header: {
                Text("Archive Export")
            } footer: {
                Text("Saves a password-encrypted archive of your message text to Files, for your own records. It can't be imported back into Relay — to move or restore your chats, use iCloud Backup above or link another device. Relay can't recover the password if you lose it.")
            }

            if let error = exportError {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                    Button("Retry") { Task { await export() } }
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRecoveryKey) {
            RecoveryKeySheet(key: backup.ensureRecoveryKey())
        }
        .sheet(isPresented: $showRestoreSheet) {
            RestoreSheet(service: service)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportItem,
            contentType: .data,
            defaultFilename: "relay-archive-\(isoDate()).relaybackup"
        ) { result in
            if case .failure(let e) = result, (e as? CocoaError)?.code != .userCancelled {
                exportError = FriendlyError.message(for: e)
            }
        }
    }

    private func export() async {
        isExporting = true
        exportError = nil
        do {
            let conversations = service.conversations
            var records = [[String: Any]]()
            for conv in conversations {
                let messages = (try? service.allMessages(in: conv.id)) ?? []
                records.append([
                    "id": conv.id,
                    "peer": conv.peerAccount,
                    "username": conv.peerUsername ?? "",
                    "messages": messages.map { msg -> [String: Any] in [
                        "id": msg.id,
                        "outgoing": msg.isOutgoing,
                        "body": msg.body,
                        "timestamp": msg.timestamp,
                        "status": msg.status.rawValue,
                    ]}
                ])
            }
            let json = try JSONSerialization.data(withJSONObject: records, options: .prettyPrinted)
            let encrypted = try encryptExport(json, password: password)
            exportItem = BackupDocument(data: encrypted)
            showingExporter = true
        } catch {
            exportError = FriendlyError.message(for: error)
        }
        isExporting = false
    }

    /// File layout: "RELAYBK2" | salt (16) | opslimit (UInt64 BE) |
    /// memlimit (UInt64 BE) | AES-GCM nonce | ciphertext | tag.
    /// The key comes from Argon2id over the password, so an attacker who gets
    /// the file has to pay a memory-hard cost per password guess (a plain hash
    /// would let them try billions per second).
    private func encryptExport(_ plaintext: Data, password: String) throws -> Data {
        _ = sodium_init()
        var salt = [UInt8](repeating: 0, count: Int(crypto_pwhash_SALTBYTES))
        randombytes_buf(&salt, salt.count)
        let opsLimit = UInt64(crypto_pwhash_OPSLIMIT_MODERATE)
        let memLimit = UInt64(crypto_pwhash_MEMLIMIT_INTERACTIVE)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let passwordLength = UInt64(password.utf8.count)
        let rc = password.withCString { pw in
            crypto_pwhash(
                &keyBytes, UInt64(keyBytes.count),
                pw, passwordLength, salt,
                opsLimit, Int(memLimit), crypto_pwhash_ALG_ARGON2ID13
            )
        }
        guard rc == 0 else { throw BackupExportError.keyDerivationFailed }
        let key = SymmetricKey(data: Data(keyBytes))
        let box = try AES.GCM.seal(plaintext, using: key)
        var out = Data("RELAYBK2".utf8)
        out.append(contentsOf: salt)
        withUnsafeBytes(of: opsLimit.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: memLimit.bigEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: box.nonce)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    enum BackupExportError: LocalizedError {
        case keyDerivationFailed
        var errorDescription: String? { "Couldn't secure the backup file. Please try again." }
    }

    private func isoDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Recovery Key sheet

private struct RecoveryKeySheet: View {
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)

                Text("Your Recovery Key")
                    .font(.title2.weight(.semibold))

                Text("Write this down and keep it safe. It's the **only** way to restore your iCloud backup — Relay and Apple can't recover it for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text(key)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                Button {
                    SecurePasteboard.copySecret(key.replacingOccurrences(of: " ", with: ""))
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Restore sheet

private struct RestoreSheet: View {
    let service: MessagingService
    @Environment(\.dismiss) private var dismiss

    @State private var keyInput = ""
    @State private var isRestoring = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Recovery Key", text: $keyInput, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Enter Your Recovery Key")
                } footer: {
                    Text("Paste the Recovery Key you saved when you enabled iCloud backup on your other device.")
                }

                Section {
                    Button {
                        Task { await restore() }
                    } label: {
                        HStack {
                            Label("Restore Messages", systemImage: "arrow.down.circle")
                            Spacer()
                            if isRestoring { ProgressView() }
                        }
                    }
                    .disabled(keyInput.filter(\.isHexDigit).count != 64 || isRestoring)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if done {
                    Section { Label("Messages restored.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            .navigationTitle("Restore from iCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func restore() async {
        isRestoring = true
        error = nil
        do {
            try await CloudBackupManager.shared.restore(
                recoveryKey: keyInput, accountId: service.credentials.accountId, into: service
            )
            done = true
        } catch {
            self.error = FriendlyError.message(for: error)
        }
        isRestoring = false
    }
}
