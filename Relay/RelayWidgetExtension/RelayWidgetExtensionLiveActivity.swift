//
//  RelayWidgetExtensionLiveActivity.swift
//  RelayWidgetExtension
//
//  Live Activity shown in the Dynamic Island and on the lock screen during
//  an active Relay voice or video call.
//

import ActivityKit
import WidgetKit
import SwiftUI

// NOTE: RelayCallAttributes is also defined in the main app target (CallLiveActivity.swift).
// Both definitions must stay in sync — ActivityKit matches by bundle identifier, not type name.
struct RelayCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isMuted: Bool
        var startedAt: Date
    }

    let peerName: String
    let isVideo: Bool
}

struct RelayWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RelayCallAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 14) {
                Image(systemName: context.attributes.isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.peerName)
                        .font(.headline)
                    Text("Relay \(context.attributes.isVideo ? "video" : "voice") call")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.callout.monospacedDigit().weight(.semibold))
                    if context.state.isMuted {
                        Label("Muted", systemImage: "mic.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(.black.opacity(0.9))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.isVideo ? "Video" : "Voice")
                            .font(.caption.weight(.medium))
                    } icon: {
                        Image(systemName: context.attributes.isVideo ? "video.fill" : "phone.fill")
                            .foregroundStyle(.green)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isMuted {
                        Image(systemName: "mic.slash.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.peerName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green)
                }
            } compactLeading: {
                Image(systemName: context.attributes.isVideo ? "video.fill" : "phone.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
                    .frame(maxWidth: 40)
            } minimal: {
                Image(systemName: "phone.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 10))
            }
            .widgetURL(URL(string: "relay://call"))
            .keylineTint(.green)
        }
    }
}

#Preview("Notification", as: .content, using: RelayCallAttributes(peerName: "Alice", isVideo: false)) {
    RelayWidgetExtensionLiveActivity()
} contentStates: {
    RelayCallAttributes.ContentState(isMuted: false, startedAt: .now)
    RelayCallAttributes.ContentState(isMuted: true, startedAt: .now)
}
