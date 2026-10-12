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
        let picker = SharePickerView(
            conversations: conversations,
            preselectedAccount: preselectedAccount,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "com.relay.share", code: NSUserCancelledError)
                )
            },
            onPick: { [weak self] conversationId in
                self?.submit(conversationId: conversationId)
            }
        )
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

    private func submit(conversationId: String) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            extensionContext?.cancelRequest(
                withError: NSError(domain: "com.relay.share", code: 1)
            )
            return
        }
        let ctx = extensionContext
        Task {
            let share = await extractShare(from: items, conversationId: conversationId)
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

private struct SharePickerView: View {
    let conversations: [ShareConversationSummary]
    let preselectedAccount: String?
    let onCancel: () -> Void
    let onPick: (String) -> Void

    @State private var query = ""
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
                    List(filtered) { conv in
                        Button {
                            guard !sending else { return }
                            sending = true
                            onPick(conv.id)
                        } label: {
                            HStack(spacing: 12) {
                                Group {
                                    if let data = ShareBridge.readAvatar(forConversationId: conv.id),
                                       let ui = UIImage(data: data) {
                                        Image(uiImage: ui)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        ZStack {
                                            Color.accentColor.opacity(0.2)
                                            Text(conv.initials)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(.circle)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conv.displayName).font(.body).foregroundStyle(.primary)
                                    if conv.isGroup {
                                        Text("Group").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if sending { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if !(preselectedAccount?.isEmpty ?? true),
                               conv.id == preselectedAccount, !sending {  // customIdentifier is the opaque conversation id
                                sending = true
                                onPick(conv.id)
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Search conversations")
                }
            }
            .navigationTitle("Share via Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
