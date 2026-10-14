//
//  ChatComposerViews.swift
//  Relay
//
//  Quotes, the edit/reply bars above the compose field, and attachments
//  in bubbles and waiting to send. Split out of ChatView.swift.
//

import CoreLocation
import Foundation
import MapKit
import OSLog
import PhotosUI
import RelayKit
import SecureStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Quote rendering

struct QuotedContentView: View {
    let quote: QuotedMessage
    let isOutgoing: Bool
    let authorName: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(authorName)
                    .font(.caption2.weight(.semibold))
                    .opacity(isOutgoing ? 1 : 0.8)
                Text(quote.text.isEmpty ? "Message"
                     : quote.text == MessagingService.stickerMarker ? "Sticker" : quote.text)
                    .font(.footnote)
                    .lineLimit(2)
                    .opacity(isOutgoing ? 0.8 : 0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            (isOutgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)),
            in: .rect(cornerRadius: 8)
        )
    }
}

struct EditPreviewBar: View {
    let message: StoredMessage
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(message.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Cancel")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .glassCompat(in: .rect(cornerRadius: 14))
    }
}

struct FormatButton: View {
    let symbol: String
    let tip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 36, height: 30)
                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tip)
        .help(tip)
    }
}

struct ReplyPreviewBar: View {
    let message: StoredMessage
    let isOwnAuthor: Bool
    let peerName: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint)
                .frame(width: 3, height: 34)
            if let symbol = attachmentSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Reply to \(isOwnAuthor ? "You" : peerName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(replySnippet)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Cancel")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .glassCompat(in: .rect(cornerRadius: 14))
    }

    private var attachmentSymbol: String? {
        guard let attachment = message.attachments.first else { return nil }
        if attachment.isImage { return "photo" }
        if attachment.isVideo { return "video.fill" }
        if attachment.isAudio { return "waveform" }
        return "doc.fill"
    }

    private var replySnippet: String {
        if !message.body.isEmpty { return message.body }
        guard let attachment = message.attachments.first else { return "Message" }
        if attachment.isImage { return "Photo" }
        if attachment.isVideo { return "Video" }
        if attachment.isAudio { return "Voice message" }
        return attachment.filename ?? "File"
    }
}

// MARK: - Attachments

/// Downloads an image attachment on first view and decrypts it in memory.
/// Plaintext never touches disk.
struct AttachmentImageView: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let requiresBiometric: Bool
    var senderName: String = ""
    /// Stickers: smaller, whole image visible, no rounded crop.
    var isSticker = false
    var isOutgoing = false

    @State private var image: UIImage?
    @Environment(\.relayIsMessageRequest) private var inRequest
    /// A request's media isn't downloaded or shown until it's accepted.
    private var hiddenForRequest: Bool { inRequest && !isOutgoing }
    @State private var isSensitive = false
    @State private var sensitiveRevealed = false
    @State private var gifData: Data?
    @State private var failed = false
    @State private var preview: PreviewItem?
    @State private var previewFileURL: URL?
    @State private var isUnlocked = false

    private var isGIF: Bool { attachment.contentType == "image/gif" }

    private var height: CGFloat {
        guard attachment.width > 0, attachment.height > 0 else { return 240 }
        let aspect = CGFloat(attachment.width) / CGFloat(attachment.height)
        return max(120, min(320, 240 / aspect))
    }

    var body: some View {
        Group {
            if isGIF, let data = gifData {
                AnimatedGIFView(data: data)
                    .blur(radius: (requiresBiometric && !isUnlocked) ? 18 : 0)
                    .overlay {
                        if requiresBiometric && !isUnlocked {
                            AttachmentPrivacyOverlay(label: "Unlock photo")
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        if requiresBiometric && !isUnlocked {
                            Task { await unlock() }
                        } else {
                            Task { await openPreview() }
                        }
                    }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isSticker ? .fit : .fill)
                    .blur(radius: (requiresBiometric && !isUnlocked) ? 18 : 0)
                    .overlay {
                        if requiresBiometric && !isUnlocked {
                            AttachmentPrivacyOverlay(label: "Unlock photo")
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        if requiresBiometric && !isUnlocked {
                            Task { await unlock() }
                        } else {
                            Task { await openPreview() }
                        }
                    }
            } else {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    if hiddenForRequest {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                            Text("Accept to view").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    } else if failed {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Tap to retry").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .contentShape(.rect)
                .onTapGesture { if failed { Task { await load() } } }
            }
        }
        .blur(radius: coversSensitive ? 40 : 0)
        .frame(width: isSticker ? 150 : 240, height: isSticker ? 150 : height)
        .overlay {
            if coversSensitive {
                SensitiveMediaCover(restricted: SensitiveContent.isRestricted, compact: isSticker) {
                    sensitiveRevealed = true
                }
            }
        }
        .clipShape(.rect(cornerRadius: isSticker ? 0 : 16))
        .accessibilityElement(children: coversSensitive ? .contain : .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(coversSensitive ? [] : [.isButton, .isImage])
        .accessibilityHint(coversSensitive ? "" : (requiresBiometric && !isUnlocked ? "Unlocks the photo" : "Opens the photo"))
        .task(id: "\(attachment.id)-\(hiddenForRequest)") { await load() }
        .fullScreenCover(item: $preview, onDismiss: cleanUpPreviewFile) { item in
            QuickLookPreview(url: item.url, title: senderName)
                .ignoresSafeArea()
        }
        .onDisappear { if preview == nil { cleanUpPreviewFile() } }
    }

    /// Deletes the decrypted temp file once the preview has closed.
    private func cleanUpPreviewFile() {
        TempMediaFiles.remove(previewFileURL)
        previewFileURL = nil
    }

    private func load() async {
        failed = false
        guard !hiddenForRequest else { return }
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let data = service.attachmentPlaintext(attachment) else {
            failed = true
            return
        }
        if !isOutgoing {
            isSensitive = await SensitiveContent.isSensitive(imageData: data, cacheKey: attachment.id)
        }
        if isGIF {
            gifData = data
        } else if let ui = SafeImage.image(from: data, maxPixelSize: SafeImage.inlinePixelSize) {
            image = ui
        } else {
            failed = true
        }
    }

    private var accessibilityDescription: String {
        let kind = isSticker ? "Sticker" : (isGIF ? "GIF" : "Photo")
        if coversSensitive { return "\(kind) hidden because it may be sensitive" }
        if failed { return "\(kind) failed to load. Double-tap to retry" }
        return senderName.isEmpty ? kind : "\(kind) from \(senderName)"
    }

    private var coversSensitive: Bool {
        isSensitive && (SensitiveContent.isRestricted || !sensitiveRevealed)
    }

    private func unlock() async {
        guard await BiometricGate.authenticate(reason: "Unlock this photo in Relay.") else { return }
        isUnlocked = true
    }

    private func openPreview() async {
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let data = service.attachmentPlaintext(attachment) else { return }
        let ext = UTType(mimeType: attachment.contentType)?.preferredFilenameExtension ?? "jpg"
        do {
            // Random filename + complete protection; deleted when the preview closes.
            let url = try TempMediaFiles.write(data, originalName: attachment.filename, fallbackExtension: ext)
            TempMediaFiles.remove(previewFileURL)
            previewFileURL = url
            preview = PreviewItem(url: url)
        } catch {
            Logger(subsystem: "app.relaymsg", category: "chat")
                .error("openPreview: temp write failed: \(PrivacyRedactor.error(error))")
        }
    }
}

/// Preview of an unsent attachment above the composer.
struct PendingAttachmentBar: View {
    let attachment: MessagingService.PendingAttachment
    let onPreview: () -> Void
    let onCancel: () -> Void

    private var isImage: Bool { attachment.contentType.hasPrefix("image/") }
    private var isVideo: Bool { attachment.contentType.hasPrefix("video/") }

    var body: some View {
        HStack(spacing: 10) {
            if isImage, let ui = DecodedImageCache.image(for: attachment.data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
                Text(attachment.contentType == "image/gif" ? "GIF" : "Photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                Text(attachment.filename ?? "Video")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                Text(attachment.filename ?? "File")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Cancel")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .glassCompat(in: .rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { onPreview() }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Previews the attachment")
    }
}

struct PendingAttachmentPreviewSheet: View {
    let attachments: [MessagingService.PendingAttachment]
    @Binding var caption: String
    @Binding var viewOnce: Bool
    let onRemove: (Int) -> Void
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var allowsViewOnce: Bool {
        attachments.allSatisfy { $0.contentType.hasPrefix("image/") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                            previewCard(for: attachment, index: index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                TextField("Add a caption", text: $caption, axis: .vertical).incognitoKeyboard()
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)

                if allowsViewOnce {
                    Toggle(isOn: $viewOnce) {
                        Label("View once", systemImage: viewOnce ? "eye.fill" : "eye.slash")
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 10)
            .navigationTitle(attachments.count == 1 ? "Preview" : "\(attachments.count) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSend()
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .accessibilityLabel("Send")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(attachments.isEmpty && caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func previewCard(for attachment: MessagingService.PendingAttachment, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if attachment.contentType.hasPrefix("image/"), let image = DecodedImageCache.image(for: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: attachment.contentType.hasPrefix("video/") ? "video.fill" : "doc.fill")
                        .font(.system(size: 32, weight: .semibold))
                    Text(attachment.filename ?? (attachment.contentType.hasPrefix("video/") ? "Video" : "File"))
                        .font(.footnote)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.tertiary)
            }
            Button { onRemove(index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Remove attachment")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(width: 220, height: 260)
        .clipShape(.rect(cornerRadius: 18))
    }
}
