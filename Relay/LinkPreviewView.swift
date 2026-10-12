//
//  LinkPreviewView.swift
//  Relay
//
//  Compact preview cards for URLs in messages. Only links we sent are fetched
//  (page metadata only); received links show just the domain.
//

import LinkPresentation
import RelayKit
import SwiftUI

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
}

// App-wide cache so titles survive view recycling.
private let linkPreviewCache: NSCache<NSString, NSString> = {
    let c = NSCache<NSString, NSString>()
    c.countLimit = 200
    return c
}()

// MARK: - Link preview card

struct LinkPreviewView: View {
    let url: URL
    let isOutgoing: Bool
    /// Fetched only for a message sent from here just now: re-fetching on
    /// every render (a forward, a copy from another device, each relaunch)
    /// would keep telling the site when this chat is open, and from which IP.
    var fetchAllowed = false

    @Environment(\.openURL) private var openURL
    @State private var title: String?
    @State private var fetched = false

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOutgoing ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tint))
                    .frame(width: 34, height: 34)
                    .background(
                        isOutgoing ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.tint.opacity(0.12)),
                        in: .rect(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? (url.host ?? url.absoluteString))
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(url.host ?? "")
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(0.7)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.6)
            }
            .padding(10)
            .background(
                isOutgoing ? AnyShapeStyle(.white.opacity(0.12)) : AnyShapeStyle(.fill.tertiary),
                in: .rect(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .task(id: url.absoluteString) {
            let key = url.absoluteString as NSString
            if let cached = linkPreviewCache.object(forKey: key) {
                title = cached as String
                fetched = true
                return
            }
            guard !fetched else { return }
            fetched = true
            // Never fetch received links: that would reveal our IP, and that we
            // read the message, to a server the sender chose. The Generate Link
            // Previews privacy setting disables fetching entirely.
            // Nor while a proxy hides our IP from the relay: the preview would
            // go straight to the site.
            guard isOutgoing, fetchAllowed, PrivacyPreferences.linkPreviewsEnabled,
                  RelayProxy.active == nil else { return }
            let provider = LPMetadataProvider()
            provider.shouldFetchSubresources = false
            provider.timeout = 8
            if let meta = try? await provider.startFetchingMetadata(for: url),
               let t = meta.title {
                title = t
                linkPreviewCache.setObject(t as NSString, forKey: key)
            }
        }
    }
}
