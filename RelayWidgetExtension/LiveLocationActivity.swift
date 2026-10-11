//
//  LiveLocationActivity.swift
//  RelayWidgetExtension
//
//  The live-location Live Activity's views. LiveLocationAttributes and
//  StopLiveLocationIntent mirror the app's copies; the intent runs in the app.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct LiveLocationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var expiresAt: Date
    }
    var recipientName: String
}

struct StopLiveLocationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Sharing Location"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult { .result() }
}

private let relayPink = Color(red: 0xF6 / 255, green: 0x3B / 255, blue: 1)

struct LiveLocationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveLocationAttributes.self) { context in
            HStack(spacing: 12) {
                locationBadge(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sharing live location")
                        .font(.headline)
                    Text("with \(context.attributes.recipientName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    countdown(context.state.expiresAt)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                stopButton
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.35))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    locationBadge(size: 36).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context.state.expiresAt)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: 70)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text("Sharing location").font(.headline)
                        Text(context.attributes.recipientName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    stopButton.padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: "location.fill")
                    .foregroundStyle(relayPink)
            } compactTrailing: {
                countdown(context.state.expiresAt)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "location.fill")
                    .foregroundStyle(relayPink)
            }
        }
    }

    private func locationBadge(size: CGFloat) -> some View {
        Image(systemName: "location.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(relayPink.gradient, in: .circle)
            .accessibilityHidden(true)
    }

    private func countdown(_ end: Date) -> Text {
        Text(timerInterval: Date.now...max(end, .now), countsDown: true)
    }

    private var stopButton: some View {
        Button(intent: StopLiveLocationIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .buttonBorderShape(.capsule)
    }
}
