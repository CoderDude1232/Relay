//
//  ComposerMedia.swift
//  Relay
//
//  Photos and videos picked in a chat. Each gets a tile in the composer at
//  once, then is loaded, prepared (photos re-encoded, videos compressed) and
//  sealed off the main thread, and starts uploading straight away, so Send
//  usually has nothing left to wait for.
//

import AVFoundation
import CoreTransferable
import PhotosUI
import SecureStorage
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ComposerAttachment: Identifiable {
    enum Kind { case photo, gif, video, file }
    enum Phase: Equatable {
        case loading
        case compressing(Double)
        case ready
    }

    let id = UUID()
    let kind: Kind
    var phase: Phase = .loading
    var thumbnail: UIImage?
    /// Plaintext, for the preview and the sensitive-content check.
    var pending: MessagingService.PendingAttachment?
    /// Sealed and uploading (or uploaded) once ready.
    var stored: StoredAttachment?
    /// A picked video's file, kept to prepare it again at another quality.
    var sourceURL: URL?
    var task: Task<Void, Never>?

    init(kind: Kind) { self.kind = kind }

    var isMedia: Bool { kind != .file }
    var isImage: Bool { kind == .photo || kind == .gif }
    var isReady: Bool { phase == .ready && stored != nil }

    /// Called when it leaves the composer without being sent.
    func discard(in service: MessagingService) {
        task?.cancel()
        if let stored { service.discardStagedAttachment(stored.id) }
        TempMediaFiles.remove(sourceURL)
    }

    /// Called once sent: the upload carries on under the message.
    func finishSending() {
        TempMediaFiles.remove(sourceURL)
    }

    static func kind(of item: PhotosPickerItem) -> Kind {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) { return .video }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .gif) }) { return .gif }
        return .photo
    }
}

/// A picked video copied to a temp file, never read whole into memory.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = TempMediaFiles.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

enum ComposerMediaError: LocalizedError {
    case unreadable, tooLong, tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable: "This item couldn't be prepared for sending."
        case .tooLong: "This video is too long to send. Trim it in Photos and try again."
        case .tooLarge: "This video is too large to send at original quality. Turn off Original Quality to send it compressed."
        }
    }
}

nonisolated enum ComposerMedia {
    static let thumbnailPixelSize = 240

    /// Loads, prepares and stages a picked photo or video into `attachment`.
    @MainActor
    static func prepare(_ item: PhotosPickerItem, into attachment: ComposerAttachment,
                        original: Bool, service: MessagingService) async throws {
        if attachment.kind == .video {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw ComposerMediaError.unreadable }
            attachment.sourceURL = movie.url
            attachment.thumbnail = await videoThumbnail(movie.url)
            try await prepareVideo(attachment, original: original, service: service)
        } else {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ComposerMediaError.unreadable }
            try await preparePhoto(data, into: attachment, service: service)
        }
    }

    @MainActor
    static func preparePhoto(_ data: Data, into attachment: ComposerAttachment, service: MessagingService) async throws {
        let original = Supporter.shared.hasAccountPerks
        let (clean, thumbnail) = await Task.detached(priority: .userInitiated) {
            (MediaSanitizer.photo(data, original: original),
             SafeImage.image(from: data, maxPixelSize: thumbnailPixelSize))
        }.value
        attachment.thumbnail = thumbnail
        guard let clean else { throw ComposerMediaError.unreadable }
        let pending = MessagingService.PendingAttachment(
            data: clean.data, contentType: clean.contentType,
            filename: attachment.kind == .gif ? "image.gif" : nil,
            width: clean.width, height: clean.height
        )
        try await stage(pending, into: attachment, service: service)
    }

    /// Compressed by default; `original` sends the file as it is, minus its
    /// location metadata. Safe to call again to switch quality.
    @MainActor
    static func prepareVideo(_ attachment: ComposerAttachment, original: Bool, service: MessagingService) async throws {
        guard let source = attachment.sourceURL else { throw ComposerMediaError.unreadable }
        let maxBytes = MessagingService.maxAttachmentPlaintextBytes
        attachment.phase = original ? .loading : .compressing(0)
        let data: Data
        let mime: String
        if original {
            let isQuickTime = source.pathExtension.lowercased() == "mov"
            guard let clean = await MediaSanitizer.video(at: source, quickTime: isQuickTime) else { throw ComposerMediaError.unreadable }
            guard clean.count <= maxBytes else { throw ComposerMediaError.tooLarge }
            data = clean
            mime = isQuickTime ? "video/quicktime" : "video/mp4"
        } else {
            let output: URL
            do {
                output = try await VideoCompressor.compress(source, maxBytes: maxBytes) { [weak attachment] fraction in
                    Task { @MainActor in
                        if case .compressing = attachment?.phase { attachment?.phase = .compressing(fraction) }
                    }
                }
            } catch VideoCompressor.Failure.tooLong {
                throw ComposerMediaError.tooLong
            }
            defer { TempMediaFiles.remove(output) }
            guard let compressed = try? Data(contentsOf: output, options: .mappedIfSafe) else { throw ComposerMediaError.unreadable }
            data = compressed
            mime = "video/mp4"
        }
        try Task.checkCancellation()
        let size = await videoSize(source)
        let pending = MessagingService.PendingAttachment(
            data: data, contentType: mime, filename: mime == "video/quicktime" ? "video.mov" : "video.mp4",
            width: Int(size.width), height: Int(size.height)
        )
        try await stage(pending, into: attachment, service: service)
    }

    @MainActor
    private static func stage(_ pending: MessagingService.PendingAttachment, into attachment: ComposerAttachment,
                              service: MessagingService) async throws {
        try Task.checkCancellation()
        attachment.pending = pending
        let stored = try await service.stageAttachment(pending)
        if Task.isCancelled {
            service.discardStagedAttachment(stored.id)
            throw CancellationError()
        }
        attachment.stored = stored
        attachment.phase = .ready
    }

    static func videoThumbnail(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailPixelSize, height: thumbnailPixelSize)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Display size, after rotation.
    static func videoSize(_ url: URL) async -> CGSize {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return .zero }
        let rotated = size.applying(transform)
        return CGSize(width: abs(rotated.width), height: abs(rotated.height))
    }
}

/// A sending photo or video's upload, over its bubble.
struct UploadProgressOverlay: ViewModifier {
    let fraction: Double?

    func body(content: Content) -> some View {
        content.overlay {
            if let fraction {
                ZStack {
                    Circle().fill(.black.opacity(0.45))
                    ProgressRing(fraction: fraction)
                        .padding(9)
                }
                .frame(width: 44, height: 44)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Uploading \(Int(fraction * 100)) percent")
            }
        }
    }
}
