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
                // "Https://" when the keyboard capitalised it.
                guard let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { return nil }
                return url
            }
    }

    /// The first link exactly as typed (so it can be matched in the body).
    var firstURLText: String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)),
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
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
        var normalized = urlText.lowercased().hasPrefix("http") ? urlText : "https://" + urlText
        // The scheme in lower case: "Https://" from the keyboard isn't fetchable.
        if let colon = normalized.firstIndex(of: ":") {
            normalized = normalized[..<colon].lowercased() + normalized[colon...]
        }
        guard let url = URL(string: normalized) else { return nil }
        // Relay's own links get an embed built on this device instead.
        if url.host() == "relaymsg.app" { return nil }
        // YouTube often gives LinkPresentation a title and no image; its own
        // thumbnail and oEmbed title are reliable.
        if let videoId = youTubeVideoId(url), let preview = await youTubePreview(videoId: videoId, url: url, urlText: urlText) {
            return preview
        }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        let meta = try? await provider.startFetchingMetadata(for: url)
        var title = (meta?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var imageData: Data?
        if let imageProvider = meta?.imageProvider,
           let image = await loadImage(imageProvider) {
            imageData = thumbnail(image)
        }
        // No image (or nothing at all): the page's own og:image / twitter:image.
        if imageData == nil, let tags = await pageTags(url) {
            if title.isEmpty { title = tags.title ?? "" }
            if let imageURL = tags.image { imageData = await fetchImage(imageURL).flatMap(thumbnail) }
        }
        guard !title.isEmpty || imageData != nil else { return nil }
        return MessageStore.LinkPreview(url: urlText, title: String(title.prefix(300)), image: imageData)
    }

    // MARK: YouTube

    /// The video id in youtube.com/watch?v=, youtu.be/, /shorts/, /live/ and /embed/ links.
    static func youTubeVideoId(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if parts.first == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            } else if let first = parts.first, ["shorts", "live", "embed", "v"].contains(first), parts.count > 1 {
                id = parts[1]
            }
        }
        guard let id, (6...20).contains(id.count),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }

    private static func youTubePreview(videoId: String, url: URL, urlText: String) async -> MessageStore.LinkPreview? {
        var title = ""
        var oembed = URLComponents(string: "https://www.youtube.com/oembed")!
        oembed.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoId)"),
                             URLQueryItem(name: "format", value: "json")]
        if let oembedURL = oembed.url, let data = await fetch(oembedURL, limit: 64 * 1024),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var image: Data?
        // hqdefault always exists; maxres is sharper but missing for some videos.
        for size in ["hqdefault", "mqdefault"] {
            if let thumbURL = URL(string: "https://i.ytimg.com/vi/\(videoId)/\(size).jpg"),
               let data = await fetchImage(thumbURL).flatMap(thumbnail) {
                image = data
                break
            }
        }
        guard !title.isEmpty || image != nil else { return nil }
        return MessageStore.LinkPreview(url: urlText, title: String(title.prefix(300)), image: image)
    }

    // MARK: Page tags

    /// og:/twitter: title and image from the start of the page.
    private static func pageTags(_ url: URL) async -> (title: String?, image: URL?)? {
        guard let data = await fetch(url, limit: 512 * 1024),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        func meta(_ names: [String]) -> String? {
            for name in names {
                let pattern = #"<meta[^>]+(?:property|name)\s*=\s*["']"# + NSRegularExpression.escapedPattern(for: name)
                    + #"["'][^>]*content\s*=\s*["']([^"']+)["']|<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*(?:property|name)\s*=\s*["']"#
                    + NSRegularExpression.escapedPattern(for: name) + #"["']"#
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
                else { continue }
                for group in 1...2 {
                    if let range = Range(match.range(at: group), in: html) {
                        return String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
                    }
                }
            }
            return nil
        }
        let image = meta(["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"])
            .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            .flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        return (meta(["og:title", "twitter:title"]), image)
    }

    private static func fetchImage(_ url: URL) async -> UIImage? {
        guard let data = await fetch(url, limit: 8 * 1024 * 1024) else { return nil }
        return SafeImage.image(from: data)
    }

    /// GET with no cookies or cache, giving up past `limit` bytes.
    private static func fetch(_ url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await previewSession.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch { return nil }
        return data
    }

    private static let previewSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    /// Scaled down and compressed to fit the 48 KiB limit receivers accept.
    static func thumbnail(_ image: UIImage) -> Data? {
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
                Image(systemName: URL(string: preview.url).flatMap(RelayLink.init)?.symbol ?? "safari")
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
