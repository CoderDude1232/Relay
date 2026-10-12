//
//  Stickers.swift
//  Relay
//
//  Stickers are ordinary E2E-encrypted image attachments whose body is
//  `MessagingService.stickerMarker`; receivers draw them without a bubble, and
//  older app versions see a photo. Sources: a built-in emoji pack rendered on
//  the fly, and "My Stickers" cut from the user's photos with Vision subject
//  lifting, kept on this device only (complete file protection).
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import PhotosUI
import SwiftUI
import UIKit
import Vision

enum StickerRenderer {
    static let size: CGFloat = 384

    /// Big emoji as a transparent PNG.
    static func emojiPNG(_ emoji: String) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { _ in
            let font = UIFont.systemFont(ofSize: size * 0.8)
            let text = NSAttributedString(string: emoji, attributes: [.font: font])
            let bounds = text.boundingRect(with: CGSize(width: size, height: size), options: .usesLineFragmentOrigin, context: nil)
            text.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
        }
        return image.pngData()
    }

    /// Cuts the main subject out of a photo (people, pets, objects) and returns
    /// it as a transparent PNG, trimmed and scaled to sticker size. Nil when
    /// Vision finds no subject.
    static func subjectPNG(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let source = SafeImage.image(from: data, maxPixelSize: 2048)?.normalizedUp(), let cg = source.cgImage else { return nil }
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            guard (try? handler.perform([request])) != nil,
                  let result = request.results?.first,
                  let buffer = try? result.generateMaskedImage(
                      ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
            else { return nil }
            let ci = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, size / max(ci.extent.width, ci.extent.height))
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let context = CIContext()
            guard let out = context.createCGImage(scaled, from: scaled.extent) else { return nil }
            return UIImage(cgImage: out).pngData()
        }.value
    }
}

private extension UIImage {
    /// Redraws so pixel data matches `.up` (Vision ignores EXIF orientation on CGImage).
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }
    }
}

/// The user's own stickers, as PNG files in Application Support.
@Observable
@MainActor
final class MyStickerStore {
    static let shared = MyStickerStore()
    private(set) var ids: [String] = []

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Stickers", isDirectory: true)
    }

    private init() {
        excludeFromBackup()
        reload()
    }

    /// Stickers are often cut from photos of people; they stay off iCloud
    /// and computer backups, which iOS doesn't encrypt with Relay's keys.
    private func excludeFromBackup() {
        var dir = directory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        ids = files
            .filter { $0.pathExtension == "png" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    func url(_ id: String) -> URL { directory.appendingPathComponent(id + ".png") }

    func data(_ id: String) -> Data? { try? Data(contentsOf: url(id)) }

    func add(_ png: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup()
        let id = UUID().uuidString
        try? png.write(to: url(id), options: [.atomic, .completeFileProtection])
        ids.insert(id, at: 0)
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
        ids.removeAll { $0 == id }
    }

    /// Sign-out: remove everything.
    func wipe() {
        try? FileManager.default.removeItem(at: directory)
        ids = []
    }
}

struct StickerPickerSheet: View {
    let onSend: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var store = MyStickerStore.shared
    @State private var photoItem: PhotosPickerItem?
    @State private var working = false
    @State private var errorMessage: String?

    static let emojiPack = ["😀", "😂", "🥹", "😍", "😎", "🤔", "😴", "🥳", "😭", "😡", "🤯", "🫡",
                            "👍", "👎", "👏", "🙏", "💪", "🤝", "❤️", "🔥", "✨", "🎉", "💯", "👀",
                            "🐶", "🐱", "🦊", "🐼", "🍕", "☕️", "🌈", "🚀"]

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Pack", selection: $tab) {
                    Text("Emoji").tag(0)
                    Text("My Stickers").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    if tab == 0 {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Self.emojiPack, id: \.self) { emoji in
                                Button {
                                    if let png = StickerRenderer.emojiPNG(emoji) { send(png) }
                                } label: {
                                    Text(emoji).font(.system(size: 52)).frame(width: 76, height: 76)
                                }
                                .accessibilityLabel("Send \(emoji) sticker")
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16).fill(.fill.tertiary)
                                    if working { ProgressView() } else {
                                        Image(systemName: "plus").font(.title2)
                                    }
                                }
                                .frame(width: 76, height: 76)
                            }
                            .disabled(working)
                            .accessibilityLabel("Make a sticker from a photo")

                            ForEach(store.ids, id: \.self) { id in
                                Button {
                                    if let png = store.data(id) { send(png) }
                                } label: {
                                    AsyncStickerThumb(url: store.url(id))
                                }
                                .contextMenu {
                                    Button(role: .destructive) { store.delete(id) } label: {
                                        Label("Delete Sticker", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                        Text(errorMessage ?? "Pick a photo and Relay cuts out the person, pet or object in it. Your stickers stay on this device.")
                            .font(.footnote)
                            .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                working = true
                errorMessage = nil
                Task {
                    defer { working = false; photoItem = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        errorMessage = "Couldn't open that photo."
                        return
                    }
                    if let png = await StickerRenderer.subjectPNG(from: data) {
                        store.add(png)
                    } else {
                        errorMessage = "Couldn't find a person, pet or object to cut out. Try a photo with a clear subject."
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send(_ png: Data) {
        onSend(png)
        dismiss()
    }
}

private struct AsyncStickerThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: 76, height: 76)
        .task(id: url) { image = UIImage(contentsOfFile: url.path) }
    }
}
