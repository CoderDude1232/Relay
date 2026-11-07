//
//  WhatsAppImportView.swift
//  Relay
//
//  Import a WhatsApp chat: WhatsApp → chat → Export Chat → Relay (the share
//  extension hands the file over), or Settings → Chats → Import from
//  WhatsApp with a file saved to Files.
//

import SecureStorage
import SwiftUI
import UniformTypeIdentifiers

struct WhatsAppImportView: View {
    let service: MessagingService
    /// An export the share extension staged; nil to start by choosing a file.
    var stagedFile: URL?
    var onOpenChat: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .intro
    @State private var me: String?
    @State private var target: String?
    @State private var progress = 0.0
    @State private var choosingFile = false

    private enum Phase {
        case intro, reading
        case choose(WhatsAppExport)
        case importing(WhatsAppExport)
        case done(added: Int, conversationId: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .modifier(ThemedPageBackground())
                .navigationTitle("Import from WhatsApp")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if !isImporting { Button("Close") { dismiss() } }
                    }
                }
        }
        .interactiveDismissDisabled(isImporting)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.zip, .plainText]) { result in
            if case .success(let url) = result { read(pickedFile: url) }
        }
        .task {
            if let stagedFile { read(stagedFile) }
        }
        .onDisappear { Self.clearInbox() }
    }

    private var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .intro:
            intro
        case .reading:
            ProgressView("Reading the export…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .choose(let export):
            chooser(export)
        case .importing:
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .frame(maxWidth: 260)
                Text("Importing…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let added, let conversationId):
            ContentUnavailableView {
                Label {
                    Text(added == 0 ? "Already Imported" : "Imported")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } description: {
                Text(added == 0
                     ? "Every message in this export is already in the chat."
                     : "\(added.formatted()) \(added == 1 ? "message" : "messages") added to the chat.")
            } actions: {
                Button("Open Chat") {
                    onOpenChat(conversationId)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Import", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another File") { choosingFile = true }
            }
        }
    }

    // MARK: - Intro

    private var intro: some View {
        List {
            Section {
                step(1, "Open the chat in WhatsApp and tap its name at the top.")
                step(2, "Tap **Export Chat**, then **Attach Media** to bring photos and videos too.")
                step(3, "Choose **Relay** in the share sheet.")
            } header: {
                Text("Bring your chat history")
            } footer: {
                Text("Messages are read on this iPhone and stay on it. Nothing is sent to the people in the chat, to WhatsApp or to Relay's servers.")
            }
            Section {
                Button("Choose an Export in Files") { choosingFile = true }.tint(.primary)
            } footer: {
                Text("If you saved the export to Files instead.")
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: .circle)
            Text(text)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Choosing

    private func chooser(_ export: WhatsAppExport) -> some View {
        let targets = service.importTargets(for: export)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(export.title ?? "WhatsApp chat")
                        .font(.headline)
                    Text(summary(export))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(export.senders, id: \.self) { name in
                    Button { me = name } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if me == name {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Which one is you?")
            } footer: {
                Text("Your messages show on your side of the chat.")
            }

            Section {
                if targets.isEmpty {
                    Text(export.isGroup
                         ? "Make the group in Relay first, then import into it."
                         : "Start a chat with them in Relay first, then import into it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(targets) { conversation in
                    Button { target = conversation.id } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: name(of: conversation), size: 36,
                                       imageData: conversation.isGroup ? nil : service.peerAvatarData(forAccount: conversation.peerAccount))
                            Text(name(of: conversation))
                            Spacer()
                            if target == conversation.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Add to which Relay chat?")
            } footer: {
                Text("The history is added to this chat on this iPhone only. Nobody else is sent anything.")
            }

            Section {
                Button {
                    start(export)
                } label: {
                    Text("Import \(export.messages.count.formatted()) Messages")
                        .frame(maxWidth: .infinity)
                }
                .disabled(me == nil || target == nil)
            }
        }
    }

    private func summary(_ export: WhatsAppExport) -> String {
        var parts = ["\(export.messages.count.formatted()) messages"]
        if let first = export.messages.first?.date, let last = export.messages.last?.date {
            let style = Date.FormatStyle.dateTime.month(.abbreviated).year()
            let from = first.formatted(style), to = last.formatted(style)
            parts.append(from == to ? from : "\(from) – \(to)")
        }
        if !export.media.isEmpty {
            parts.append(export.media.count == 1 ? "1 photo or file" : "\(export.media.count.formatted()) photos and files")
        }
        return parts.joined(separator: " · ")
    }

    private func name(of conversation: Conversation) -> String {
        if conversation.isGroup { return conversation.peerUsername ?? "Group" }
        return service.displayName(forAccount: conversation.peerAccount)
    }

    // MARK: - Work

    private func read(pickedFile url: URL) {
        // Copied into the inbox, so the import doesn't depend on Files access.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let inbox = ShareBridge.whatsAppImportInbox() else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: inbox)
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let copy = inbox.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.copyItem(at: url, to: copy)
            read(copy)
        } catch {
            phase = .failed("The file couldn't be opened.")
        }
    }

    private func read(_ url: URL) {
        phase = .reading
        Task {
            do {
                let export = try await Task.detached(priority: .userInitiated) {
                    try WhatsAppExport.read(url)
                }.value
                let targets = service.importTargets(for: export)
                me = guessMe(export)
                target = guessTarget(export, targets: targets)
                phase = .choose(export)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// In a 1:1 export named after the other person, you're the other sender;
    /// otherwise the sender with your Relay name.
    private func guessMe(_ export: WhatsAppExport) -> String? {
        if let mine = service.myDisplayName,
           let match = export.senders.first(where: { $0.caseInsensitiveCompare(mine) == .orderedSame }) {
            return match
        }
        if !export.isGroup, let title = export.title, export.senders.contains(title) {
            return export.senders.first { $0 != title }
        }
        return nil
    }

    private func guessTarget(_ export: WhatsAppExport, targets: [Conversation]) -> String? {
        var names = Set(export.senders.filter { $0 != me }.map { $0.lowercased() })
        if let title = export.title { names.insert(title.lowercased()) }
        return targets.first { names.contains(name(of: $0).lowercased()) }?.id
    }

    private func start(_ export: WhatsAppExport) {
        guard let me, let target else { return }
        phase = .importing(export)
        progress = 0
        Task {
            do {
                let added = try await service.importWhatsApp(export, me: me, into: target) { progress = $0 }
                Self.clearInbox()
                phase = .done(added: added, conversationId: target)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    static func clearInbox() {
        guard let inbox = ShareBridge.whatsAppImportInbox() else { return }
        try? FileManager.default.removeItem(at: inbox)
    }

    /// The export the share extension left, if any.
    static func stagedExport() -> URL? {
        guard let inbox = ShareBridge.whatsAppImportInbox() else { return nil }
        return (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil))?.first
    }
}
