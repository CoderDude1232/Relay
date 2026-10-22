//
//  LinkPreviewView.swift
//  Relay
//
//  Link preview cards. The sender builds a preview (title and a small image)
//  while composing and sends it inside the encrypted message, so receivers
//  never contact the site. Links without one show a compact domain card.
//

import LinkPresentation
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

// MARK: - URL detection helper

extension String {
    var firstURL: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        return detector.firstMatch(in: self, range: range)
            .flatMap { $0.url }
            .flatMap { url in
                guard let scheme = url.scheme,
                      scheme == "http" || scheme == "https" else { return nil }
                return url
            }
    }

    /// The first link exactly as typed (so it can be matched in the body).
    var firstURLText: String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)),
              let url = match.url, url.scheme == "http" || url.scheme == "https",
              let range = Range(match.range, in: self)
        else { return nil }
        return String(self[range])
    }
}

// MARK: - Building a preview (sender only)

enum LinkPreviewBuilder {
    /// Fetches the page's title and image for a message being written. Off
    /// when link previews are turned off or a proxy hides our IP (the fetch
    /// would go straight to the site).
    static func build(for urlText: String) async -> MessageStore.LinkPreview? {
        guard PrivacyPreferences.linkPreviewsEnabled, RelayProxy.active == nil else { return nil }
        let normalized = urlText.lowercased().hasPrefix("http") ? urlText : "https://" + urlText
        guard let url = URL(string: normalized) else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        guard let meta = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let title = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var imageData: Data?
        if let imageProvider = meta.imageProvider,
           let image = await loadImage(imageProvider) {
            imageData = thumbnail(image)
        }
        guard !title.isEmpty || imageData != nil else { return nil }
        return MessageStore.LinkPreview(url: urlText, title: String(title.prefix(300)), image: imageData)
    }

    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    /// Scaled down and compressed to fit the 48 KiB limit receivers accept.
    private static func thumbnail(_ image: UIImage) -> Data? {
        for side: CGFloat in [600, 420, 300] {
            let scale = min(1, side / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality: CGFloat in [0.7, 0.5, 0.35] {
                if let data = scaled.jpegData(compressionQuality: quality), data.count <= 48 * 1024 {
                    return data
                }
            }
        }
        return nil
    }
}

// MARK: - Card in a message

struct LinkPreviewView: View {
    let url: URL
    let isOutgoing: Bool
    /// The preview sent with the message, if any.
    var preview: MessageStore.LinkPreview? = nil

    @Environment(\.openURL) private var openURL

    private var image: UIImage? { preview?.image.flatMap { SafeImage.image(from: $0) } }
    private var title: String? { preview.flatMap { $0.title.isEmpty ? nil : $0.title } }
    private var domain: String {
        (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        Button { openURL(url) } label: {
            if let image {
                largeCard(image)
            } else {
                compactCard
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "Link: \($0), \(domain)" } ?? "Link to \(domain)")
        .accessibilityAddTraits(.isLink)
    }

    private func largeCard(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 140)
                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(domain)
                    .font(.caption)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 280)
        .background(cardFill, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var compactCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "safari")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOutgoing ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.tint))
                .frame(width: 34, height: 34)
                .background(
                    isOutgoing ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.tint.opacity(0.12)),
                    in: .rect(cornerRadius: 8)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? domain)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if title != nil {
                    Text(domain)
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(0.7)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption2.weight(.semibold))
                .opacity(0.6)
        }
        .padding(10)
        .frame(maxWidth: 280)
        .background(cardFill, in: .rect(cornerRadius: 10))
    }

    private var cardFill: AnyShapeStyle {
        isOutgoing ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(.fill.tertiary)
    }
}

// MARK: - Composer card

/// Above the composer while a link's preview is ready; × sends without it.
struct ComposerLinkPreview: View {
    let preview: MessageStore.LinkPreview
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let data = preview.image, let image = SafeImage.image(from: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "safari")
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title.isEmpty ? preview.url : preview.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(URL(string: preview.url)?.host() ?? preview.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Link preview: \(preview.title.isEmpty ? preview.url : preview.title)")
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send without preview")
        }
        .padding(10)
        .glassCompat(in: .rect(cornerRadius: 18))
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
