//
//  RelayWidgetExtensionLiveActivity.swift
//  RelayWidgetExtension
//
//  Created by Ethan Daly on 29/8/2026.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct RelayWidgetExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct RelayWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RelayWidgetExtensionAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension RelayWidgetExtensionAttributes {
    fileprivate static var preview: RelayWidgetExtensionAttributes {
        RelayWidgetExtensionAttributes(name: "World")
    }
}

extension RelayWidgetExtensionAttributes.ContentState {
    fileprivate static var smiley: RelayWidgetExtensionAttributes.ContentState {
        RelayWidgetExtensionAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: RelayWidgetExtensionAttributes.ContentState {
         RelayWidgetExtensionAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: RelayWidgetExtensionAttributes.preview) {
   RelayWidgetExtensionLiveActivity()
} contentStates: {
    RelayWidgetExtensionAttributes.ContentState.smiley
    RelayWidgetExtensionAttributes.ContentState.starEyes
}
