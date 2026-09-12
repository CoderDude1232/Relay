//
//  BackupView.swift
//  Relay
//
//  Exports an encrypted JSON backup of all conversations + messages
//  to the Files app (or any share destination). The export is
//  encrypted with a one-time password the user sets.
//

import CryptoKit
import SecureStorage
import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    let service: MessagingService

    @State private var password = ""
    @State private var confirm = ""
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportItem: BackupDocument?
    @State private var showingExporter = false

    private var canExport: Bool {
        password.count >= 8 && password == confirm
    }

    var body: some View {
        List {
            Section {
                SecureField("Password (min 8 characters)", text: $password)
                SecureField("Confirm password", text: $confirm)
            } header: {
                Text("Set Export Password")
            } footer: {
                Text("Creates an encrypted export of your messages. Protected by AES-256-GCM — Relay cannot recover the password if lost.")
            }

            Section {
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
            }

            if let error = exportError {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                    Button("Retry") {
                        Task { await export() }
                    }
                }
            }
        }
        .navigationTitle("Backup & Export")
        .navigationBarTitleDisplayMode(.inline)
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
