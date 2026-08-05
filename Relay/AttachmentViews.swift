//
//  AttachmentViews.swift
//  Relay
//
//  Renders non-image attachments inside message bubbles: voice messages
//  (play/pause with a progress track) and generic files (icon, name, size,
//  and open/share). Both download the ciphertext on first view and decrypt
//  to memory on demand — plaintext is written to a temp file only when the
//  user explicitly opens/shares a file.
//

import SecureStorage
import SwiftUI
import UniformTypeIdentifiers

extension StoredAttachment {
    var isImage: Bool { contentType.hasPrefix("image/") }
    var isAudio: Bool { contentType.hasPrefix("audio/") }
}

// MARK: - Voice message

/// A voice-message bubble: tap to play/pause with a live progress track and a
/// duration label. Styled to read against the parent message bubble's fill.
struct VoiceNoteBubble: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool

    @State private var player = VoicePlayer()
    @State private var data: Data?
    @State private var failed = false

    private var tint: Color { isOutgoing ? .white : .primary }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let data { player.toggle(data) }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.18), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(data == nil)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.25)).frame(height: 4)
                    Capsule().fill(tint).frame(width: geo.size.width * player.progress, height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 34)

            Text(failed ? "—" : label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint.opacity(0.85))
        }
        .frame(width: 200)
        .task(id: attachment.id) { await load() }
    }

    private var label: String {
        if player.isPlaying || player.progress > 0 {
            return formatDuration(player.progress * player.duration)
        }
        return player.duration > 0 ? formatDuration(player.duration) : "Voice"
    }

    private func load() async {
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        if let plaintext = service.attachmentPlaintext(attachment) {
            data = plaintext
            player.prepare(plaintext)
        } else {
            failed = true
        }
    }
}

// MARK: - Generic file

/// A file-attachment bubble: document icon, filename, and size. Tapping
/// downloads (if needed), decrypts to a temp file, and presents the share
/// sheet so the file can be opened in another app or saved.
struct FileAttachmentBubble: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool

    @State private var share: ShareItem?
    @State private var busy = false

    private var tint: Color { isOutgoing ? .white : .primary }

    var body: some View {
        Button {
            Task { await open() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.18))
                        .frame(width: 40, height: 40)
                    if busy {
                        ProgressView().tint(tint)
                    } else {
                        Image(systemName: "doc.fill").font(.system(size: 18)).foregroundStyle(tint)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename ?? "File")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sizeLabel)
                        .font(.caption)
                        .foregroundStyle(tint.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .frame(width: 220)
        }
        .buttonStyle(.plain)
        .sheet(item: $share) { item in ActivityView(url: item.url) }
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file)
    }

    private func open() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let plaintext = service.attachmentPlaintext(attachment) else { return }
        let name = attachment.filename ?? "file"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try plaintext.write(to: url, options: .atomic)
            share = ShareItem(url: url)
        } catch {}
    }
}

/// Wraps a temp file URL so it can drive a `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal UIActivityViewController bridge for sharing/opening a file.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
