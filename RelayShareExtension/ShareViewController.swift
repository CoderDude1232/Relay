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
            ShareBridge.writePendingShare(share)
            if let url = URL(string: "relay://pending-share") {
                await ctx?.open(url)
            }
            ctx?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Content extraction

    private func extractShare(
        from items: [NSExtensionItem],
        conversationId: String
    ) async -> PendingShare {
        for item in items {
            for provider in item.attachments ?? [] {
                // Image: use loadDataRepresentation (not deprecated)
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadData(provider, type: UTType.image.identifier) {
                        return PendingShare(conversationId: conversationId, text: nil,
                                           imageData: data, imageUTI: UTType.jpeg.identifier,
                                           fileData: nil, filename: nil)
                    }
                }
                // URL: use loadObject(ofClass: NSURL.self)
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(provider) {
                        return PendingShare(conversationId: conversationId, text: url.absoluteString,
                                           imageData: nil, imageUTI: nil, fileData: nil, filename: nil)
                    }
                }
                // Text: load as data + decode
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let data = await loadData(provider, type: UTType.plainText.identifier),
                       let text = String(data: data, encoding: .utf8) {
                        return PendingShare(conversationId: conversationId, text: text,
                                           imageData: nil, imageUTI: nil, fileData: nil, filename: nil)
                    }
                }
                // Generic file: copy to temp dir via loadFileRepresentation
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

    private func loadFile(_ provider: NSItemProvider) async -> (Data, String)? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let name = url.lastPathComponent
                let data = try? Data(contentsOf: url)
                continuation.resume(returning: data.map { ($0, name) })
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
