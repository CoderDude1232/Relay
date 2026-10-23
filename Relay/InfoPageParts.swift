//
//  InfoPageParts.swift
//  Relay
//
//  Pieces shared by the contact and group info pages: the header, the round
//  quick-action buttons and the shared-media row.
//

import SecureStorage
import SwiftUI
import UIKit

/// Large photo on a soft glow of the chat's colour, then name and subtitle.
struct InfoHeader<Photo: View, Accessory: View>: View {
    let name: String
    var subtitle: String? = nil
    @ViewBuilder let photo: Photo
    /// Beside the name (e.g. a rename button).
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 10) {
            photo
                .background {
                    // Small enough to fade out inside the list row, which clips.
                    Circle()
                        .fill(AvatarView.color(for: name).opacity(0.3))
                        .frame(width: 128, height: 128)
                        .blur(radius: 22)
                        .accessibilityHidden(true)
                }
            HStack(spacing: 6) {
                Text(name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                accessory
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 4)
    }
}

extension InfoHeader where Accessory == EmptyView {
    init(name: String, subtitle: String? = nil, @ViewBuilder photo: () -> Photo) {
        self.name = name
        self.subtitle = subtitle
        self.photo = photo()
        self.accessory = EmptyView()
    }
}

/// A round glass button with a caption, for the row under an info header.
struct InfoQuickAction: View {
    let icon: String
    let label: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 46)
                    .glassCompat(in: .rect(cornerRadius: 18))
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.primary)
            .opacity(isDisabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// "Media, Links & Files" with the newest photos, opening the full gallery.
/// Thumbnails stay hidden when the chat's media needs Face ID.
struct SharedMediaRow: View {
    let service: MessagingService
    let conversationId: String

    @State private var photos: [StoredAttachment] = []
    @State private var total = 0

    private var locked: Bool {
        service.conversations.first { $0.id == conversationId }?.mediaRequiresBiometric ?? true
    }

    var body: some View {
        NavigationLink {
            MediaGalleryView(service: service, conversationId: conversationId)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "photo.stack.fill", color: .teal)
                    Text("Media, Links & Files").foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if total > 0 {
                        Text("\(total)").foregroundStyle(.secondary)
                    }
                    if locked && total > 0 {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Locked")
                    }
                }
                if !locked && !photos.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(photos.prefix(4), id: \.id) { attachment in
                            MediaRowThumbnail(attachment: attachment, service: service)
                        }
                        ForEach(0..<max(0, 4 - photos.count), id: \.self) { _ in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .task(id: conversationId) { load() }
    }

    private func load() {
        let messages = (try? service.allMessages(in: conversationId)) ?? []
        // View-once media only ever shows in the chat itself.
        let visible = messages.filter { !$0.isDeleted && !$0.body.hasPrefix(MessagingService.viewOncePrefix) }
        var recent: [StoredAttachment] = []
        var count = 0
        for message in visible.reversed() {
            for attachment in message.attachments where !attachment.isAudio {
                count += 1
                if attachment.isImage, recent.count < 4 { recent.append(attachment) }
            }
            if message.body.firstURL != nil { count += 1 }
        }
        photos = recent
        total = count
    }
}

/// A photo already on this device; nothing is downloaded for the row.
private struct MediaRowThumbnail: View {
    let attachment: StoredAttachment
    let service: MessagingService

    @State private var image: UIImage?
    @State private var isSensitive = false

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: isSensitive ? 24 : 0)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .task(id: attachment.id) {
                guard image == nil, let data = service.attachmentPlaintext(attachment),
                      let ui = SafeImage.image(from: data) else { return }
                isSensitive = await SensitiveContent.isSensitive(image: ui, cacheKey: attachment.id)
                image = ui
            }
    }
}
