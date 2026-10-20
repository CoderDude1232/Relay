//
//  AdaptiveNavigation.swift
//  Relay
//
//  A list-and-detail screen: a navigation stack on iPhone, a split view on
//  iPad, where the list sits in the floating sidebar (like Chats) and the
//  pages it opens fill the space beside it.
//

import SwiftUI

struct AdaptiveNavigation<Sidebar: View, Placeholder: View>: View {
    @ViewBuilder var sidebar: Sidebar
    /// Shown beside the list until something is opened.
    @ViewBuilder var placeholder: Placeholder

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                sidebar
                    .modifier(SidebarListBackground(useWallpaper: false))
                    .sidebarTabBar()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360)
            } detail: {
                // Its own stack, so pages opened from a page get a back button.
                NavigationStack { placeholder }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                sidebar
            }
        }
    }
}

/// iPad list columns: plain black or white like the rest of the app (not the
/// sidebar's grey), or for the chat list the chat wallpaper, so the list and
/// the open chat share one background.
struct SidebarListBackground: ViewModifier {
    let useWallpaper: Bool
    @Environment(ChatAppearance.self) private var appearance
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .scrollContentBackground(.hidden)
                .background {
                    Group {
                        if useWallpaper { appearance.background } else { Color(.systemBackground) }
                    }
                    .ignoresSafeArea()
                }
        } else {
            content
        }
    }
}
