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

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        Group {
            if mediaMessages.isEmpty {
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
                                GalleryThumbnail(attachment: attachment, service: service) { image in
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
        .onAppear { loadMedia() }
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
        mediaMessages = source.filter { !$0.attachments.filter { $0.isImage }.isEmpty }
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
        if let data = service.attachmentPlaintext(attachment),
           let ui = UIImage(data: data) {
            withAnimation { image = ui }
        }
    }
}
