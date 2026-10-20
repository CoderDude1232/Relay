//
//  SidebarTabBar.swift
//  Relay
//
//  iPad tabs: a floating glass bar at the foot of each tab's list column.
//

import SwiftUI

struct SidebarTabs {
    var selection: Binding<Int>
    var chatsBadge: Int
    var callsBadge: Int
    var avatarData: Data?
    var profileName: String
}

extension EnvironmentValues {
    /// Set by the iPad layout; nil on iPhone, which uses the system tab bar.
    @Entry var sidebarTabs: SidebarTabs? = nil
}

extension View {
    /// Floats the iPad tab bar at the bottom of a list column.
    func sidebarTabBar() -> some View {
        modifier(SidebarTabBarInset())
    }
}

private struct SidebarTabBarInset: ViewModifier {
    @Environment(\.sidebarTabs) private var tabs

    func body(content: Content) -> some View {
        if let tabs {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarTabBar(tabs: tabs)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        } else {
            content
        }
    }
}

private struct SidebarTabBar: View {
    let tabs: SidebarTabs

    var body: some View {
        GlassContainer {
            HStack(spacing: 2) {
                item(0, "Chats", badge: tabs.chatsBadge) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                }
                item(1, "Calls", badge: tabs.callsBadge) {
                    Image(systemName: "phone.fill")
                }
                item(2, "Profile", badge: 0) {
                    AvatarView(name: tabs.profileName, size: 24, imageData: tabs.avatarData)
                }
            }
            .padding(4)
            .glassCompat(in: .capsule)
        }
        .frame(maxWidth: 320)
    }

    private func item<Icon: View>(_ tag: Int, _ title: String, badge: Int, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = tabs.selection.wrappedValue == tag
        return Button {
            tabs.selection.wrappedValue = tag
        } label: {
            VStack(spacing: 2) {
                icon()
                    .font(.system(size: 19, weight: .semibold))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(.red, in: .capsule)
                                .offset(x: 10, y: -5)
                        }
                    }
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) new" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
