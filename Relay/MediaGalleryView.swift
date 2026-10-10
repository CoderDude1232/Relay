//
//  MediaGalleryView.swift
//  Relay
//
//  Full-screen grid of all images shared in a conversation.
//  Tap a thumbnail for full-screen view.
//

import SecureStorage
import SwiftUI

struct MediaGalleryView: View {
    let service: MessagingService
    let conversationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var mediaMessages: [StoredMessage] = []
    @State private var fullScreenImage: UIImage?
    /// False until the per-chat "Require Face ID for media" gate is passed.
    @State private var unlocked = false
    @State private var isAuthenticating = false

    /// Mirrors ChatView: an unknown conversation requires auth (fail closed).
    private var requiresBiometric: Bool {
        service.conversations.first { $0.id == conversationId }?.mediaRequiresBiometric ?? true
    }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        Group {
            if !unlocked {
                ContentUnavailableView {
                    Label("Media Locked", systemImage: "lock.fill")
                } description: {
                    Text("Unlock with \(BiometricGate.biometryName) to view this chat's media.")
                } actions: {
                    Button("Unlock") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isAuthenticating)
                }
            } else if mediaMessages.isEmpty {
                ContentUnavailableView(
                    "No Media",
                    systemImage: "photo.stack",
                    description: Text("Photos shared in this conversation appear here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(mediaMessages) { message in
                            ForEach(message.attachments.filter { $0.isImage }) { attachment in
                                GalleryThumbnail(attachment: attachment, service: service, conversationId: conversationId) { image in
                                    fullScreenImage = image
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .task { await unlock() }
        .fullScreenCover(item: Binding(
            get: { fullScreenImage.map { IdentifiableImage(image: $0) } },
            set: { if $0 == nil { fullScreenImage = nil } }
        )) { item in
            FullScreenImageView(image: item.image, service: service)
        }
    }

    private func loadMedia() {
        // Prefer already-loaded activeMessages; fall back to a full DB read.
        let source: [StoredMessage]
        if service.activeConversationId == conversationId {
            source = service.activeMessages
        } else {
            source = (try? service.allMessages(in: conversationId)) ?? []
        }
        // View-once media is only shown inline in the chat, never here.
        mediaMessages = source.filter {
            !$0.body.hasPrefix(MessagingService.viewOncePrefix)
                && $0.attachments.contains { $0.isImage }
        }
    }

    private func unlock() async {
        guard !unlocked, !isAuthenticating else { return }
        if requiresBiometric {
            isAuthenticating = true
            let ok = await BiometricGate.authenticate(reason: "View media in this chat.")
            isAuthenticating = false
            guard ok else { return }
        }
        unlocked = true
        loadMedia()
    }
}

// MARK: - Helpers

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct GalleryThumbnail: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let onTap: (UIImage) -> Void

    @State private var image: UIImage?

    @State private var isLoading = false

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect)
            .contentShape(.rect)
            .onTapGesture { if let image { onTap(image) } }
            .task { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        isLoading = true
        defer { isLoading = false }
        var data = service.attachmentPlaintext(attachment)
        if data == nil {
            // Not cached (never downloaded, or cleared). downloadAttachment is
            // idempotent and honours the Wi-Fi-only setting.
            await service.downloadAttachment(attachment, in: conversationId)
            data = service.attachmentPlaintext(attachment)
        }
        if let data, let ui = UIImage(data: data) {
            withAnimation { image = ui }
        }
    }
}
