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
                    .modifier(ThemedPageBackground(isSidebar: true))
                    .sidebarTabBar()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360)
            } detail: {
                // Its own stack, so pages opened from a page get a back button.
                NavigationStack {
                    placeholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(ThemedPageBackground())
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                sidebar
                    .modifier(ThemedPageBackground())
            }
        }
    }
}

/// Behind a tab's lists and pages: the theme when one is set (on iPhone
/// too), otherwise plain black or white in an iPad list column rather than
/// the sidebar's grey.
///
/// `isSidebar` comes from outside the split view: its list column is always
/// compact-width, even on iPad.
struct ThemedPageBackground: ViewModifier {
    var isSidebar = false
    @Environment(ChatAppearance.self) private var appearance

    func body(content: Content) -> some View {
        if appearance.hasWallpaper {
            content
                .scrollContentBackground(.hidden)
                .background { appearance.pageBackground.ignoresSafeArea() }
        } else if isSidebar {
            content
                .scrollContentBackground(.hidden)
                .background { Color(.systemBackground).ignoresSafeArea() }
        } else {
            content
        }
    }
}
