//
//  ShareViewController.swift
//  RelayShareExtension
//

import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        var preselectedAccount: String?
        if let intent = extensionContext?.intent as? INSendMessageIntent {
            preselectedAccount = intent.recipients?.first?.customIdentifier
        }

        let conversations = ShareBridge.readConversations()
        let model = SharePreviewModel()
        self.previewModel = model
        let picker = SharePickerView(
            conversations: conversations,
            preselectedAccount: preselectedAccount,
            preview: model,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "com.relay.share", code: NSUserCancelledError)
                )
            },
            onPick: { [weak self] conversationId, caption in
                self?.submit(conversationId: conversationId, caption: caption)
            }
        )
        // Read what's being shared up front, to show it above the chats.
        if let items = extensionContext?.inputItems as? [NSExtensionItem] {
            Task { [weak self] in
                guard let self else { return }
                let share = await self.extractShare(from: items, conversationId: "")
                model.share = share
                model.loaded = true
            }
        }
        let host = UIHostingController(rootView: picker)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    private var previewModel: SharePreviewModel?

    private func submit(conversationId: String, caption: String) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            extensionContext?.cancelRequest(
                withError: NSError(domain: "com.relay.share", code: 1)
            )
            return
        }
        let ctx = extensionContext
        let loaded = previewModel?.share
        Task {
            let base: PendingShare
            if let loaded {
                base = loaded
            } else {
                base = await extractShare(from: items, conversationId: conversationId)
            }
            var share = PendingShare(conversationId: conversationId, text: base.text,
                                     imageData: base.imageData, imageUTI: base.imageUTI,
                                     fileData: base.fileData, filename: base.filename)
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { share.caption = trimmed }
            if share.text == nil, share.imageData == nil, share.fileData == nil, sawTooLarge {
                showTooLarge()
                return
            }
            ShareBridge.writePendingShare(share)
            if let url = URL(string: "relay://pending-share") {
                await ctx?.open(url)
            }
            ctx?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Content extraction

    /// The relay takes attachments up to about 26 MB; anything bigger can't be
    /// sent, and reading it into the extension's memory could get it killed.
    private static let maxShareBytes = 25 * 1024 * 1024
    private var sawTooLarge = false

    private func showTooLarge() {
        let alert = UIAlertController(
            title: "Too Large to Send",
            message: "Relay can send files up to 25 MB.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "com.relay.share", code: 2))
        })
        present(alert, animated: true)
    }

    private func extractShare(
        from items: [NSExtensionItem],
        conversationId: String
    ) async -> PendingShare {
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadData(provider, type: UTType.image.identifier) {
                        guard data.count <= Self.maxShareBytes else {
                            sawTooLarge = true
                            continue
                        }
                        return PendingShare(conversationId: conversationId, text: nil,
                                           imageData: data, imageUTI: UTType.jpeg.identifier,
                                           fileData: nil, filename: nil)
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(provider) {
                        return PendingShare(conversationId: conversationId, text: url.absoluteString,
                                           imageData: nil, imageUTI: nil, fileData: nil, filename: nil)
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let data = await loadData(provider, type: UTType.plainText.identifier),
                       let text = String(data: data, encoding: .utf8) {
                        return PendingShare(conversationId: conversationId, text: text,
                                           imageData: nil, imageUTI: nil, fileData: nil, filename: nil)
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    if let (fileData, filename) = await loadFile(provider) {
                        return PendingShare(conversationId: conversationId, text: nil,
                                           imageData: nil, imageUTI: nil,
                                           fileData: fileData, filename: filename)
                    }
                }
            }
            if let text = item.attributedContentText?.string, !text.isEmpty {
                return PendingShare(conversationId: conversationId, text: text,
                                    imageData: nil, imageUTI: nil, fileData: nil, filename: nil)
            }
        }
        return PendingShare(conversationId: conversationId, text: nil,
                            imageData: nil, imageUTI: nil, fileData: nil, filename: nil)
    }

    private func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { obj, _ in
                continuation.resume(returning: obj as? URL)
            }
        }
    }

    private enum LoadedFile { case file(Data, String), tooLarge, unavailable }

    private func loadFile(_ provider: NSItemProvider) async -> (Data, String)? {
        switch await loadFileChecked(provider) {
        case .file(let data, let name): return (data, name)
        case .tooLarge:
            sawTooLarge = true
            return nil
        case .unavailable: return nil
        }
    }

    private func loadFileChecked(_ provider: NSItemProvider) async -> LoadedFile {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                guard let url else { continuation.resume(returning: .unavailable); return }
                let name = url.lastPathComponent
                // Check the size before reading it all into memory.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxShareBytes else {
                    continuation.resume(returning: .tooLarge)
                    return
                }
                let data = try? Data(contentsOf: url)
                continuation.resume(returning: data.map { .file($0, name) } ?? .unavailable)
            }
        }
    }
}

// MARK: - SwiftUI conversation picker

/// Relay's accent (the app's AccentColor; the extension has no asset of its own).
private let relayAccent = Color(red: 0xF6 / 255, green: 0x3B / 255, blue: 1)

/// What's being shared, read when the sheet opens.
@Observable
final class SharePreviewModel {
    var share: PendingShare?
    var loaded = false
}

private struct SharePickerView: View {
    let conversations: [ShareConversationSummary]
    let preselectedAccount: String?
    let preview: SharePreviewModel
    let onCancel: () -> Void
    let onPick: (String, String) -> Void

    @State private var query = ""
    @State private var caption = ""
    @State private var selected: String?
    @State private var sending = false

    private var filtered: [ShareConversationSummary] {
        query.isEmpty ? conversations
            : conversations.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Open Relay and send a message first.")
                    )
                } else {
                    List {
                        Section {
                            sharedItem
                            TextField("Add a message…", text: $caption, axis: .vertical)
                                .lineLimit(1...4)
                        }
                        if query.isEmpty, conversations.count > 3 {
                            Section("Recent") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(conversations.prefix(8)) { conv in
                                            Button { toggle(conv.id) } label: {
                                                VStack(spacing: 6) {
                                                    avatar(conv, size: 54)
                                                        .overlay(alignment: .bottomTrailing) { checkmark(conv.id) }
                                                    Text(conv.displayName)
                                                        .font(.caption)
                                                        .lineLimit(1)
                                                        .frame(width: 64)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityAddTraits(selected == conv.id ? .isSelected : [])
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            }
                        }
                        Section(query.isEmpty ? "All Chats" : "Results") {
                            ForEach(filtered) { conv in
                                Button { toggle(conv.id) } label: {
                                    HStack(spacing: 12) {
                                        avatar(conv, size: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(conv.displayName).font(.body).foregroundStyle(.primary)
                                            if conv.isGroup {
                                                Text("Group").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: selected == conv.id ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selected == conv.id ? relayAccent : Color(.tertiaryLabel))
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected == conv.id ? .isSelected : [])
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Search chats")
                }
            }
            .tint(relayAccent)
            .navigationTitle("Send with Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            guard let selected else { return }
                            sending = true
                            onPick(selected, caption)
                        }
                        .bold()
                        .disabled(selected == nil)
                    }
                }
            }
            .onAppear {
                // Siri suggestion: that chat is chosen already.
                if let preselectedAccount, conversations.contains(where: { $0.id == preselectedAccount }) {
                    selected = preselectedAccount
                }
            }
        }
    }

    private static func avatarColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[Int(hash.magnitude % UInt(palette.count))]
    }

    private func toggle(_ id: String) {
        selected = selected == id ? nil : id
    }

    @ViewBuilder
    private var sharedItem: some View {
        HStack(spacing: 12) {
            if let share = preview.share {
                if let data = share.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 10))
                    Text("Photo").foregroundStyle(.secondary)
                } else if let name = share.filename {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundStyle(relayAccent)
                        .frame(width: 56, height: 56)
                        .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 10))
                    Text(name).lineLimit(2)
                } else if let text = share.text {
                    Image(systemName: text.hasPrefix("http") ? "link" : "text.alignleft")
                        .font(.title3)
                        .foregroundStyle(relayAccent)
                        .frame(width: 56, height: 56)
                        .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 10))
                    Text(text).lineLimit(3).font(.subheadline)
                } else {
                    Text("Nothing to share").foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .frame(width: 56, height: 56)
                Text("Loading…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func checkmark(_ id: String) -> some View {
        if selected == id {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, relayAccent)
                .background(Circle().fill(.background))
        }
    }

    private func avatar(_ conv: ShareConversationSummary, size: CGFloat) -> some View {
        Group {
            if let data = ShareBridge.readAvatar(forConversationId: conv.id),
               let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                // The same colours as avatars in the app.
                ZStack {
                    Rectangle().fill(Self.avatarColor(conv.displayName).gradient)
                    Text(conv.initials)
                        .font(size > 48 ? .headline : .subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}
