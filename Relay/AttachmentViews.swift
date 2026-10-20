//
//  AttachmentViews.swift
//  Relay
//

import AVFoundation
import AVKit
import ImageIO
import OSLog
import QuickLook
import SecureStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension StoredAttachment {
    var isImage: Bool { contentType.hasPrefix("image/") }
    var isAudio: Bool { contentType.hasPrefix("audio/") }
    var isVideo: Bool { contentType.hasPrefix("video/") }
}

// MARK: - Voice message

extension VoiceNoteBubble where Trailing == EmptyView {
    init(attachment: StoredAttachment, service: MessagingService, conversationId: String,
         isOutgoing: Bool, requiresBiometric: Bool) {
        self.init(attachment: attachment, service: service, conversationId: conversationId,
                  isOutgoing: isOutgoing, requiresBiometric: requiresBiometric) { EmptyView() }
    }
}

struct VoiceNoteBubble<Trailing: View>: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool
    let requiresBiometric: Bool
    /// Shown at the end of the duration line (the message's time and status).
    @ViewBuilder var trailing: Trailing

    @State private var player = VoicePlayer()
    @State private var data: Data?
    @State private var failed = false
    @State private var isUnlocked = false
    @State private var transcript: String?
    @State private var isTranscribing = false
    @State private var showTranscript = false
    @Environment(\.relayIsMessageRequest) private var inRequest
    @Environment(ChatAppearance.self) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tint: Color { isOutgoing ? .white : .primary }
    /// Behind Face ID in this chat: shown as a locked player (no waveform,
    /// no transcript) rather than blurred.
    private var locked: Bool { requiresBiometric && !isUnlocked }
    /// Audio from someone not yet accepted isn't downloaded or parsed.
    private var heldForRequest: Bool { inRequest && !isOutgoing }

    @State private var levels: [Float] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await unlockAndTogglePlayback() }
                } label: {
                    Image(systemName: locked ? "lock.fill" : player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isOutgoing ? appearance.bubbleTint : .white)
                        .frame(width: 38, height: 38)
                        .background(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor), in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(locked ? "Unlock voice message" : player.isPlaying ? "Pause" : "Play voice message")
                .disabled(data == nil && !failed)

                VStack(alignment: .leading, spacing: 4) {
                    VoiceWaveform(levels: locked ? [] : levels, progress: player.progress, tint: tint)
                        .frame(height: 24)
                        .accessibilityHidden(true)
                    durationLine
                }
            }
            .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 220)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)

            if locked {
                EmptyView()
            } else if let transcript {
                Text(transcript)
                    .font(.footnote)
                    .foregroundStyle(tint.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 220, alignment: .leading)
            } else if #available(iOS 26.0, *), AIAssistant.isOnDeviceTranscriptionAvailable, data != nil {
                // Transcription runs on-device only; hidden where that's unsupported.
                Button {
                    Task { await transcribeVoiceNote() }
                } label: {
                    HStack(spacing: 4) {
                        if isTranscribing {
                            ProgressView().controlSize(.mini).tint(tint)
                            Text("Transcribing…")
                        } else {
                            Image(systemName: "text.bubble")
                            Text("Transcribe")
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint.opacity(0.75))
                }
                .buttonStyle(.plain)
                .disabled(isTranscribing)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { Task { await unlockAndTogglePlayback() } }
        .task(id: "\(attachment.id)|\(heldForRequest)") {
            guard !heldForRequest else { return }
            await load()
        }
    }

    /// Duration (or status), the speed button while playing, and the time and
    /// status passed in. At accessibility text sizes the time gets its own line.
    @ViewBuilder
    private var durationLine: some View {
        let status = Text(heldForRequest ? "Accept to play" : locked ? "Tap to unlock" : failed ? "Couldn't load" : label)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(tint.opacity(0.75))
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    status
                    Spacer(minLength: 0)
                    rateButton
                }
                HStack {
                    Spacer(minLength: 0)
                    trailing
                }
            }
        } else {
            HStack(spacing: 6) {
                status
                Spacer(minLength: 0)
                rateButton
                trailing
            }
        }
    }

    @ViewBuilder
    private var rateButton: some View {
        if player.isPlaying || player.progress > 0 {
            Button {
                player.cycleRate()
            } label: {
                Text(rateLabel)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed \(rateLabel)")
        }
    }

    private var label: String {
        if player.isPlaying || player.progress > 0 {
            return formatDuration(player.progress * player.duration)
        }
        return player.duration > 0 ? formatDuration(player.duration) : "Voice"
    }

    private var rateLabel: String {
        switch player.rate {
        case 1.5: return "1.5x"
        case 2.0: return "2x"
        default:  return "1x"
        }
    }

    private func load() async {
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        if let plaintext = service.attachmentPlaintext(attachment) {
            data = plaintext
            player.prepare(plaintext)
            levels = await VoiceWaveform.levels(for: plaintext)
        } else {
            failed = true
        }
    }

    private func unlockAndTogglePlayback() async {
        guard let data else { return }
        if requiresBiometric && !isUnlocked {
            guard await BiometricGate.authenticate(reason: "Unlock this voice note in Relay.") else { return }
            isUnlocked = true
        }
        player.toggle(data)
    }

    private func transcribeVoiceNote() async {
        guard #available(iOS 26.0, *) else { return }
        guard let data, !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let text = try await AIAssistant.shared.transcribe(
                audioData: data,
                contentType: attachment.contentType
            )
            transcript = text.isEmpty ? "(no speech detected)" : text
        } catch {
            transcript = "(transcription failed)"
        }
    }
}

// MARK: - Generic file

struct FileAttachmentBubble: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool
    let requiresBiometric: Bool
    var senderName: String = ""

    @State private var preview: PreviewItem?
    @State private var tempFileURL: URL?
    @State private var busy = false
    @State private var isUnlocked = false
    /// A flagged file waiting for the adult's "View Anyway".
    @State private var sensitivePreview: PreviewItem?
    @State private var showingSensitiveHelp = false
    @Environment(\.relayIsMessageRequest) private var inRequest

    private var tint: Color { isOutgoing ? .white : .primary }
    /// Files from someone not yet accepted aren't downloaded or opened.
    private var heldForRequest: Bool { inRequest && !isOutgoing }

    /// Types QuickLook renders as web content, which can load remote
    /// resources and so tell a sender's server the file was opened (and from
    /// which IP). They open as plain text instead.
    private static let webContentExtensions: Set<String> = [
        "html", "htm", "xhtml", "shtml", "svg", "svgz", "xml", "webarchive", "mht", "mhtml",
    ]

    var body: some View {
        Button {
            Task { await open() }
        } label: {
            ZStack {
                fileContent
                    .blur(radius: requiresBiometric && !isUnlocked ? 8 : 0)
                if requiresBiometric && !isUnlocked {
                    AttachmentPrivacyOverlay(label: "Unlock attachment")
                }
            }
            .frame(maxWidth: 280)
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "This may be sensitive",
            isPresented: Binding(get: { sensitivePreview != nil }, set: { if !$0 { sensitivePreview = nil } }),
            titleVisibility: .visible
        ) {
            Button("View Anyway") {
                preview = sensitivePreview
                sensitivePreview = nil
            }
            Button("Cancel", role: .cancel) {
                sensitivePreview = nil
                cleanUpPreview()
            }
        } message: {
            Text("This file may show nudity.")
        }
        .sheet(isPresented: $showingSensitiveHelp) { SensitiveContentHelpView() }
        .fullScreenCover(item: $preview, onDismiss: cleanUpPreview) { item in
            QuickLookPreview(url: item.url, title: item.title)
                .ignoresSafeArea()
        }
        .onDisappear { if preview == nil { cleanUpPreview() } }
    }

    private func isSensitiveFile(_ data: Data, at url: URL) async -> Bool {
        guard SensitiveContent.isEnabled else { return false }
        if SafeImage.isImage(data) {
            return await SensitiveContent.isSensitive(imageData: data, cacheKey: attachment.id)
        }
        return await SensitiveContent.isSensitive(videoAt: url, cacheKey: attachment.id)
    }

    /// Deletes the decrypted temp file once the preview has closed.
    private func cleanUpPreview() {
        TempMediaFiles.remove(tempFileURL)
        tempFileURL = nil
    }

    private var fileContent: some View {
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
                Text(heldForRequest ? "Accept to open" : sizeLabel)
                    .font(.caption)
                    .foregroundStyle(tint.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file)
    }

    private func open() async {
        guard !busy, !heldForRequest else { return }
        if requiresBiometric && !isUnlocked {
            guard await BiometricGate.authenticate(reason: "Unlock this attachment in Relay.") else { return }
            isUnlocked = true
        }
        busy = true
        defer { busy = false }
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let plaintext = service.attachmentPlaintext(attachment) else { return }
        do {
            // Random filename + complete protection; deleted when the preview closes.
            let ext = ((attachment.filename ?? "") as NSString).pathExtension.lowercased()
            let isWebContent = Self.webContentExtensions.contains(ext)
                || attachment.contentType.contains("html") || attachment.contentType.contains("svg")
            let url = try TempMediaFiles.write(plaintext, originalName: isWebContent ? nil : attachment.filename,
                                               fallbackExtension: isWebContent ? "txt" : "")
            TempMediaFiles.remove(tempFileURL)
            tempFileURL = url
            let item = PreviewItem(url: url, title: attachment.filename ?? senderName)
            // A file can be a photo or video under any name or type: check the
            // bytes, not the declared kind.
            if await isSensitiveFile(plaintext, at: url) {
                if SensitiveContent.isRestricted {
                    cleanUpPreview()
                    showingSensitiveHelp = true
                } else {
                    sensitivePreview = item
                }
                return
            }
            preview = item
        } catch {
            Logger(subsystem: "app.relaymsg", category: "attachments")
                .error("openPreview: temp write failed: \(PrivacyRedactor.error(error))")
        }
    }
}

// MARK: - Video player bubble

struct VideoPlayerBubble: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool
    let requiresBiometric: Bool

    @State private var playerURL: URL?
    @State private var busy = false
    @State private var failed = false
    @State private var isUnlocked = false
    @State private var showingPlayer = false
    @State private var sensitiveChecked = false
    @State private var isSensitive = false
    @State private var confirmSensitive = false
    @Environment(\.relayIsMessageRequest) private var inRequest

    private var tint: Color { isOutgoing ? .white : .primary }

    var body: some View {
        Button { Task { await load() } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.12))
                    .frame(width: 200, height: 120)
                if busy {
                    ProgressView().tint(tint)
                } else if failed {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                        Text("Failed").font(.caption).foregroundStyle(tint.opacity(0.7))
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: playerURL != nil ? "play.fill" : "arrow.down.circle")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(inRequest && !isOutgoing ? "Accept to view" : playerURL != nil ? "Play Video" : (attachment.isDownloaded ? "Open" : "Download"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(tint.opacity(0.85))
                    }
                }
                if requiresBiometric && !isUnlocked {
                    AttachmentPrivacyOverlay(label: "Unlock video")
                }
                if isSensitive && SensitiveContent.isRestricted {
                    SensitiveMediaCover(restricted: true) {}
                        .frame(width: 200, height: 120)
                        .clipShape(.rect(cornerRadius: 12))
                }
            }
        }
        .buttonStyle(.plain)
        .alert("This video may be sensitive", isPresented: $confirmSensitive) {
            Button("View") { showingPlayer = true }
            Button("Cancel", role: .cancel) { cleanUpPlayerFile() }
        } message: {
            Text("Relay checked it on this iPhone and it may contain nudity.")
        }
        .fullScreenCover(isPresented: $showingPlayer, onDismiss: cleanUpPlayerFile) {
            if let url = playerURL {
                VideoPlayerSheet(url: url)
            }
        }
        .onDisappear { if !showingPlayer { cleanUpPlayerFile() } }
    }

    private func load() async {
        guard !busy, !(isSensitive && SensitiveContent.isRestricted), !(inRequest && !isOutgoing) else { return }
        if requiresBiometric && !isUnlocked {
            guard await BiometricGate.authenticate(reason: "Unlock this video in Relay.") else { return }
            isUnlocked = true
        }
        if playerURL != nil {
            if isSensitive { confirmSensitive = true } else { showingPlayer = true }
            return
        }
        busy = true
        defer { busy = false }
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let plaintext = service.attachmentPlaintext(attachment) else { failed = true; return }
        do {
            // Random filename + complete protection; deleted when the player closes.
            let url = try TempMediaFiles.write(plaintext, originalName: attachment.filename, fallbackExtension: "mp4")
            playerURL = url
            if !isOutgoing && !sensitiveChecked {
                isSensitive = await SensitiveContent.isSensitive(videoAt: url, cacheKey: attachment.id)
                sensitiveChecked = true
            }
            if isSensitive {
                if SensitiveContent.isRestricted { cleanUpPlayerFile() } else { confirmSensitive = true }
                return
            }
            showingPlayer = true
        } catch { failed = true }
    }

    /// Deletes the decrypted temp file; the next play decrypts again.
    private func cleanUpPlayerFile() {
        TempMediaFiles.remove(playerURL)
        playerURL = nil
    }
}

private struct VideoPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    /// Created once: building the AVPlayer in `body` would make a new player
    /// (and restart playback) on every re-render.
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoPlayer(player: player)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(20)
            }
            .accessibilityLabel("Close")
        }
        .onDisappear { player.pause() }
    }
}

struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    var title: String = ""
}

struct AttachmentPrivacyOverlay: View {
    let label: String

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
            .accessibilityLabel(label)
    }
}

// MARK: - System bridges

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    var title: String = ""

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.done)
        )
        let nav = UINavigationController(rootViewController: controller)
        context.coordinator.nav = nav
        return nav
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url, title: title) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let item: NamedPreviewItem
        weak var nav: UINavigationController?
        init(url: URL, title: String) { item = NamedPreviewItem(url: url, title: title) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
        @objc func done() { nav?.dismiss(animated: true) }
    }
}

private final class NamedPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title.isEmpty ? nil : title
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Full-screen image preview

struct FullScreenImageView: View {
    let image: UIImage
    let service: MessagingService
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false
    @State private var forwarding = false
    @State private var chromeVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZoomableImageView(image: image) {
                withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if chromeVisible {
                topChrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible {
                bottomChrome
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [image])
        }
        .sheet(isPresented: $forwarding) {
            ForwardPickerView(image: image, service: service) { forwarding = false }
        }
    }

    private var topChrome: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.white)
                    .glassCompat(in: .circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close preview")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var bottomChrome: some View {
        HStack(spacing: 18) {
            imageActionButton(icon: "square.and.arrow.up", label: "Share") {
                sharing = true
            }
            imageActionButton(icon: "arrowshape.turn.up.right.fill", label: "Forward") {
                forwarding = true
            }
        }
        .padding(10)
        .glassCompat(in: Capsule())
        .padding(.bottom, 24)
    }

    private func imageActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 38, height: 30)
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(.white)
            .frame(width: 82, height: 62)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Zoomable image

/// A photo that zooms like Photos: pinch (or trackpad pinch), pan when
/// zoomed, double-tap to zoom in or back out; a single tap calls `onTap`.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = LayoutReportingScrollView()
        scroll.onLayout = { [weak coordinator = context.coordinator, weak scroll] in
            guard let coordinator, let scroll else { return }
            coordinator.layout(in: scroll)
        }
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Photo"
        imageView.accessibilityTraits = .image
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scroll.zoomScale = 1
        }
        context.coordinator.layout(in: scroll)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onTap: () -> Void = {}
        private var laidOutFor: CGSize = .zero

        /// Fits the image to the scroll view at zoom 1 (redone on rotation or resize).
        func layout(in scroll: UIScrollView) {
            guard let imageView, scroll.bounds.size != .zero, scroll.bounds.size != laidOutFor else { return }
            laidOutFor = scroll.bounds.size
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func singleTapped() { onTap() }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// Calls back after layout, so the photo refits on rotation and window resizes.
private final class LayoutReportingScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Animated GIF

/// Displays an animated GIF using UIImageView's built-in frame animation.
struct AnimatedGIFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        return iv
    }

    func updateUIView(_ iv: UIImageView, context: Context) {
        guard iv.animationImages == nil else { return }
        Task.detached(priority: .userInitiated) {
            let animated = Self.buildAnimatedImage(from: data)
            await MainActor.run {
                if let animated, animated.frames.count > 1 {
                    iv.animationImages = animated.frames
                    iv.animationDuration = animated.duration
                    iv.startAnimating()
                } else {
                    iv.image = animated?.frames.first
                }
            }
        }
    }

    nonisolated private static func buildAnimatedImage(from data: Data) -> (frames: [UIImage], duration: Double)? {
        SafeImage.animation(from: data)
    }
}

// MARK: - Forward picker

struct ForwardPickerView: View {
    let image: UIImage
    let service: MessagingService
    let onDismiss: () -> Void

    @State private var isSending = false

    private var conversations: [Conversation] {
        service.conversations.filter { !$0.archived && $0.peerAccount != service.relayOfficialAccount }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right", description: Text("Start a conversation first."))
                } else {
                    List(conversations) { conv in
                        Button { forward(to: conv.id) } label: {
                            let account = conv.groupId ?? conv.peerAccount
                            HStack(spacing: 12) {
                                AvatarView(
                                    name: service.displayName(forAccount: account),
                                    size: 44,
                                    imageData: conv.isGroup
                                        ? service.group(for: conv.id)?.avatarData
                                        : service.peerAvatarData(forAccount: account)
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(service.displayName(forAccount: account))
                                        .font(.body.weight(.medium))
                                    if !conv.isGroup, let username = conv.peerUsername {
                                        Text("@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(isSending)
                    }
                }
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
            }
            .overlay {
                if isSending { ProgressView() }
            }
        }
    }

    private func forward(to conversationId: String) {
        guard !isSending else { return }
        isSending = true
        let data = image.jpegData(compressionQuality: 0.9) ?? Data()
        let attachment = MessagingService.PendingAttachment(
            data: data, contentType: "image/jpeg", filename: nil,
            width: Int(image.size.width), height: Int(image.size.height)
        )
        Task {
            await service.sendMessage("", in: conversationId, attachments: [attachment])
            onDismiss()
        }
    }
}


// MARK: - Voice waveform

/// Bars drawn from the clip's loudness; the played part takes the full tint.
struct VoiceWaveform: View {
    let levels: [Float]
    let progress: Double
    let tint: Color

    static let barCount = 32

    var body: some View {
        GeometryReader { geo in
            let bars = levels.isEmpty ? Array(repeating: Float(0.15), count: Self.barCount) : levels
            let spacing: CGFloat = 2
            let width = max(1.5, (geo.size.width - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                    let played = Double(index) / Double(bars.count) < progress
                    Capsule()
                        .fill(played ? tint : tint.opacity(0.35))
                        .frame(width: width, height: max(3, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Peak loudness in `barCount` slices, scaled to 0...1. Read from a
    /// protected temp copy, off the main thread.
    nonisolated static func levels(for data: Data) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            guard let url = try? TempMediaFiles.write(data, originalName: nil, fallbackExtension: "m4a") else { return [] }
            defer { TempMediaFiles.remove(url) }
            guard let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(min(file.length, 48_000 * 600))),
                  (try? file.read(into: buffer)) != nil,
                  let samples = buffer.floatChannelData?[0]
            else { return [] }
            let count = Int(buffer.frameLength)
            guard count > barCount else { return [] }
            let slice = count / barCount
            var peaks: [Float] = (0..<barCount).map { bar in
                var peak: Float = 0
                var i = bar * slice
                let end = min(count, i + slice)
                while i < end { peak = max(peak, abs(samples[i])); i += 4 }
                return peak
            }
            let top = peaks.max() ?? 0
            guard top > 0 else { return [] }
            peaks = peaks.map { 0.12 + 0.88 * ($0 / top) }
            return peaks
        }.value
    }
}
