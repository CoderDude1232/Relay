//
//  SensitiveContent.swift
//  Relay
//
//  On-device nudity detection via Apple's SensitiveContentAnalysis. Only active
//  when the user has turned on Sensitive Content Warning, or Communication
//  Safety is on for a child account. Nothing leaves the device.
//
//  Adults get a blurred cover with "View". Under Communication Safety
//  (descriptive interventions) flagged media can't be opened or sent.
//

import SensitiveContentAnalysis
import SwiftUI
import UIKit

@MainActor
enum SensitiveContent {
    private static let analyzer = SCSensitivityAnalyzer()
    private static var cache: [String: Bool] = [:]

    static var isEnabled: Bool { analyzer.analysisPolicy != .disabled }
    /// Communication Safety on a child account.
    static var isRestricted: Bool { analyzer.analysisPolicy == .descriptiveInterventions }

    static func isSensitive(image: UIImage, cacheKey: String? = nil) async -> Bool {
        guard isEnabled else { return false }
        if let cacheKey, let known = cache[cacheKey] { return known }
        guard let cgImage = image.cgImage ?? rasterized(image) else { return false }
        let result = (try? await analyzer.analyzeImage(cgImage))?.isSensitive ?? false
        if let cacheKey { cache[cacheKey] = result }
        return result
    }

    static func isSensitive(imageData data: Data, cacheKey: String? = nil) async -> Bool {
        guard isEnabled else { return false }
        if let cacheKey, let known = cache[cacheKey] { return known }
        guard let image = UIImage(data: data) else { return false }
        return await isSensitive(image: image, cacheKey: cacheKey)
    }

    static func isSensitive(videoAt url: URL, cacheKey: String? = nil) async -> Bool {
        guard isEnabled else { return false }
        if let cacheKey, let known = cache[cacheKey] { return known }
        let handler = analyzer.videoAnalysis(forFileAt: url)
        let result = (try? await handler.hasSensitiveContent())?.isSensitive ?? false
        if let cacheKey { cache[cacheKey] = result }
        return result
    }

    private static func rasterized(_ image: UIImage) -> CGImage? {
        UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }.cgImage
    }

    static let helpURL = URL(string: "https://support.apple.com/HT212850")!
}

/// Cover over flagged media in a chat.
struct SensitiveMediaCover: View {
    let restricted: Bool
    var compact = false
    let onView: () -> Void

    @State private var showingHelp = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: compact ? 6 : 10) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: compact ? 22 : 28, weight: .regular))
                Text(restricted ? "Hidden for your safety" : "This may be sensitive")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                if restricted {
                    Button("Ways to get help") { showingHelp = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                } else {
                    Button("View", action: onView)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
            .foregroundStyle(.primary)
            .padding(10)
        }
        .contentShape(.rect)
        .onTapGesture {}
        .sheet(isPresented: $showingHelp) { SensitiveContentHelpView() }
    }
}

/// Shown to children under Communication Safety.
struct SensitiveContentHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("This photo or video may show private body parts")
                        .font(.title3.weight(.semibold))
                    Text("Relay hid it, and it can't be opened on this phone. You haven't done anything wrong.")
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Talk to a parent or another adult you trust.", systemImage: "person.2.fill")
                        Label("You can block the person who sent it from their chat info.", systemImage: "hand.raised.slash.fill")
                        Label("Never feel pressured to send photos or videos back.", systemImage: "heart.fill")
                    }
                    Button {
                        openURL(SensitiveContent.helpURL)
                    } label: {
                        Text("More help from Apple")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
