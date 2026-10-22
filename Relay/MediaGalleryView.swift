//
//  MediaGalleryView.swift
//  Relay
//
//  Everything shared in a conversation, in tabs: photos (a grid that opens a
//  swipeable viewer), videos, files and links.
//

import SecureStorage
import SwiftUI

struct MediaGalleryView: View {
    let service: MessagingService
    let conversationId: String

    private enum Tab: String, CaseIterable {
        case photos = "Photos", videos = "Videos", files = "Files", links = "Links"
    }

    /// One shared item with the message it came in.
    struct Item: Identifiable {
        let attachment: StoredAttachment
        let message: StoredMessage
        var id: String { attachment.id }
    }

    private struct LinkItem: Identifiable {
        let url: URL
        let message: StoredMessage
        var id: String { message.id + url.absoluteString }
    }

    @State private var tab: Tab = .photos
    @State private var photos: [Item] = []
    @State private var videos: [Item] = []
    @State private var files: [Item] = []
    @State private var links: [LinkItem] = []
    @State private var viewerStart: Item?
    @State private var preview: PreviewItem?
    @State private var playerURL: URL?
    @State private var showingPlayer = false
    @State private var sensitiveVideo: URL?
    @State private var safariURL: URL?
    /// False until the per-chat "Require Face ID for media" gate is passed.
    @State private var unlocked = false
    @State private var isAuthenticating = false

    /// Mirrors ChatView: an unknown conversation requires auth (fail closed).
    private var requiresBiometric: Bool {
        service.conversations.first { $0.id == conversationId }?.mediaRequiresBiometric ?? true
    }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

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
            } else {
                VStack(spacing: 0) {
                    Picker("Media type", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    content
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .task { await unlock() }
        .fullScreenCover(item: $viewerStart) { start in
            PhotoPagerView(items: photos, start: start, service: service, conversationId: conversationId)
        }
        .fullScreenCover(item: $preview, onDismiss: cleanUpPreview) { item in
            QuickLookPreview(url: item.url, title: item.title).ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingPlayer, onDismiss: cleanUpPlayer) {
            if let playerURL { VideoPlayerSheet(url: playerURL) }
        }
        .alert("This video may be sensitive", isPresented: Binding(
            get: { sensitiveVideo != nil }, set: { if !$0 { sensitiveVideo = nil } }
        )) {
            Button("View") {
                playerURL = sensitiveVideo
                sensitiveVideo = nil
                showingPlayer = true
            }
            Button("Cancel", role: .cancel) {
                TempMediaFiles.remove(sensitiveVideo)
                sensitiveVideo = nil
            }
        } message: {
            Text("Relay checked it on this device and it may contain nudity.")
        }
        .sheet(item: $safariURL) { url in
            SafariView(url: url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .photos:
            if photos.isEmpty {
                empty("No Photos", "photo.on.rectangle", "Photos shared in this chat appear here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, item in
                            GalleryThumbnail(attachment: item.attachment, service: service, conversationId: conversationId) { _ in
                                viewerStart = item
                            }
                            .accessibilityLabel("Photo \(index + 1) of \(photos.count), \(Self.date(item.message.timestamp))")
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        case .videos:
            if videos.isEmpty {
                empty("No Videos", "video", "Videos shared in this chat appear here.")
            } else {
                List(videos) { item in
                    Button { Task { await play(item) } } label: {
                        row(icon: "play.rectangle.fill", title: item.attachment.filename ?? "Video", item: item)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        case .files:
            if files.isEmpty {
                empty("No Files", "doc", "Files shared in this chat appear here.")
            } else {
                List(files) { item in
                    Button { Task { await open(item) } } label: {
                        row(icon: "doc.fill", title: item.attachment.filename ?? "File", item: item)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        case .links:
            if links.isEmpty {
                empty("No Links", "link", "Links shared in this chat appear here.")
            } else {
                List(links) { link in
                    Button { openLink(link.url) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "link")
                                .frame(width: 36, height: 36)
                                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.url.host() ?? link.url.absoluteString)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(link.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(Self.date(link.message.timestamp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(icon: String, title: String, item: Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.attachment.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(Self.date(item.message.timestamp))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private func empty(_ title: String, _ icon: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(text))
    }

    private static func date(_ timestamp: Int64) -> String {
        Date(timeIntervalSince1970: Double(timestamp) / 1000).formatted(.dateTime.day().month(.abbreviated).year())
    }

    // MARK: Loading

    private func loadMedia() {
        // Prefer already-loaded activeMessages; fall back to a full DB read.
        let source: [StoredMessage]
        if service.activeConversationId == conversationId, !service.hasEarlierMessages {
            source = service.activeMessages
        } else {
            source = (try? service.allMessages(in: conversationId)) ?? []
        }
        // View-once media is only shown inline in the chat, never here.
        let visible = source.filter { !$0.body.hasPrefix(MessagingService.viewOncePrefix) && !$0.isDeleted }
        var p: [Item] = [], v: [Item] = [], f: [Item] = [], l: [LinkItem] = []
        for message in visible.reversed() {  // newest first
            for attachment in message.attachments {
                if attachment.isImage { p.append(Item(attachment: attachment, message: message)) }
                else if attachment.isVideo { v.append(Item(attachment: attachment, message: message)) }
                else if !attachment.isAudio { f.append(Item(attachment: attachment, message: message)) }
            }
            if let url = message.body.firstURL, !message.body.hasPrefix(locationPrefix), !message.body.hasPrefix("~loc~") {
                l.append(LinkItem(url: url, message: message))
            }
        }
        photos = p; videos = v; files = f; links = l
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

    // MARK: Opening

    private func plaintext(_ item: Item) async -> Data? {
        if let data = service.attachmentPlaintext(item.attachment) { return data }
        await service.downloadAttachment(item.attachment, in: conversationId)
        return service.attachmentPlaintext(item.attachment)
    }

    private func play(_ item: Item) async {
        guard !(SensitiveContent.isRestricted && SensitiveContent.isEnabled),
              let data = await plaintext(item),
              let url = try? TempMediaFiles.write(data, originalName: item.attachment.filename, fallbackExtension: "mp4")
        else { return }
        if SensitiveContent.isEnabled, await SensitiveContent.isSensitive(videoAt: url, cacheKey: item.attachment.id) {
            sensitiveVideo = url
        } else {
            playerURL = url
            showingPlayer = true
        }
    }

    private func open(_ item: Item) async {
        guard let data = await plaintext(item),
              let url = try? TempMediaFiles.write(data, originalName: item.attachment.filename, fallbackExtension: "bin")
        else { return }
        preview = PreviewItem(url: url, title: item.attachment.filename ?? "File")
    }

    private func openLink(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            safariURL = url
        } else {
            UIApplication.shared.open(url)
        }
    }

    private func cleanUpPreview() {
        TempMediaFiles.remove(preview?.url)
    }

    private func cleanUpPlayer() {
        TempMediaFiles.remove(playerURL)
        playerURL = nil
    }
}

// MARK: - Photo pager

/// Full-screen photos to swipe through, each zoomable, starting at `start`.
private struct PhotoPagerView: View {
    let items: [MediaGalleryView.Item]
    let start: MediaGalleryView.Item
    let service: MessagingService
    let conversationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String = ""
    @State private var chromeVisible = true
    @State private var images: [String: UIImage] = [:]
    @State private var sharing: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(items) { item in
                    Group {
                        if let image = images[item.id] {
                            ZoomableImageView(image: image) {
                                withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
                            }
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .ignoresSafeArea()
                    .tag(item.id)
                    .task { await load(item) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if chromeVisible {
                HStack {
                    if let index = items.firstIndex(where: { $0.id == selection }) {
                        Text("\(index + 1) of \(items.count)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassCompat(in: .capsule)
                    }
                    Spacer()
                    if let image = images[selection] {
                        Button { sharing = image } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .glassCompat(in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share")
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassCompat(in: .circle)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .sheet(item: Binding(
            get: { sharing.map { SharedImage(image: $0) } },
            set: { if $0 == nil { sharing = nil } }
        )) { item in
            ShareSheet(items: [item.image])
        }
        .onAppear { selection = start.id }
    }

    private struct SharedImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private func load(_ item: MediaGalleryView.Item) async {
        guard images[item.id] == nil else { return }
        var data = service.attachmentPlaintext(item.attachment)
        if data == nil {
            await service.downloadAttachment(item.attachment, in: conversationId)
            data = service.attachmentPlaintext(item.attachment)
        }
        guard let data, let image = SafeImage.image(from: data) else { return }
        // Sensitive photos stay behind the grid's cover: not shown here.
        if SensitiveContent.isEnabled, await SensitiveContent.isSensitive(image: image, cacheKey: item.attachment.id) {
            return
        }
        images[item.id] = image
    }
}

// MARK: - Thumbnail

private struct GalleryThumbnail: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let onTap: (UIImage) -> Void

    @State private var image: UIImage?

    @State private var isLoading = false
    @State private var isSensitive = false
    @State private var revealed = false

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: isSensitive && !revealed ? 30 : 0)
                        .transition(.opacity)
                    if isSensitive && !revealed {
                        SensitiveMediaCover(restricted: SensitiveContent.isRestricted, compact: true) {
                            revealed = true
                        }
                    }
                } else if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect)
            .contentShape(.rect)
            .onTapGesture { if let image, !isSensitive { onTap(image) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo")
            .accessibilityAddTraits([.isButton, .isImage])
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
        if let data, let ui = SafeImage.image(from: data) {
            isSensitive = await SensitiveContent.isSensitive(image: ui, cacheKey: attachment.id)
            withAnimation { image = ui }
        }
    }
}
