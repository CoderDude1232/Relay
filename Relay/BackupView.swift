//
//  BackupView.swift
//  Relay
//
//  Exports an encrypted JSON backup of all conversations + messages
//  to the Files app (or any share destination). The export is
//  encrypted with a one-time password the user sets.
//

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
                        Label("Export to Files", systemImage: "arrow.up.doc.fill")
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                }
                .disabled(!canExport || isExporting)
            } header: {
                Text("Manual Export")
            } footer: {
                Text("Creates a one-off encrypted file of your messages. Protected by AES-256-GCM — Relay cannot recover the password if lost.")
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
            contentType: .json,
            defaultFilename: "relay-backup-\(isoDate()).json"
        ) { result in
            if case .failure(let e) = result { exportError = e.localizedDescription }
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
            exportError = error.localizedDescription
        }
        isExporting = false
    }

    private func encryptExport(_ plaintext: Data, password: String) throws -> Data {
        let salt = SymmetricKey(size: .bits256)
        var saltBytes = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltBytes = Array($0) }
        let keyData = saltBytes.withUnsafeBytes { saltPtr in
            Array(HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
                salt: Data(saltBytes),
                outputByteCount: 32
            ).withUnsafeBytes { Array($0) })
        }
        let key = SymmetricKey(data: Data(keyData))
        let box = try AES.GCM.seal(plaintext, using: key)
        var out = Data(saltBytes)
        out.append(contentsOf: box.nonce)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    private func isoDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
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
                    UIPasteboard.general.string = key.replacingOccurrences(of: " ", with: "")
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
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isRestoring = false
    }
}
