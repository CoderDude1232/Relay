//
//  SidebarTabBar.swift
//  Relay
//
//  iPad tabs: the system tab bar, at the foot of each tab's list column.
//

import SwiftUI
import UIKit

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
                // Like the iPhone tab bar, it runs down into the
                // home-indicator area and lays itself out above it.
                SidebarTabBar(tabs: tabs)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        } else {
            content
        }
    }
}

/// The system tab bar itself, owned by a real tab bar controller in the
/// iPhone (compact) layout, so it looks and behaves exactly like the iPhone
/// one. The controller's pages are empty; the split views show the content.
private struct SidebarTabBar: UIViewControllerRepresentable {
    let tabs: SidebarTabs

    func makeUIViewController(context: Context) -> TabBarHost {
        TabBarHost()
    }

    func updateUIViewController(_ host: TabBarHost, context: Context) {
        host.onSelect = { tabs.selection.wrappedValue = $0 }
        host.update(selected: tabs.selection.wrappedValue,
                    chatsBadge: tabs.chatsBadge, callsBadge: tabs.callsBadge,
                    avatarData: tabs.avatarData)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController host: TabBarHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: host.barHeight)
    }

    final class TabBarHost: UITabBarController, UITabBarControllerDelegate {
        var onSelect: ((Int) -> Void)?
        private var avatarKey: Int?

        var barHeight: CGFloat {
            view.layoutIfNeeded()
            return max(tabBar.frame.height, 60)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            traitOverrides.horizontalSizeClass = .compact
            view.backgroundColor = .clear
            delegate = self
            let items = [
                UITabBarItem(title: "Chats", image: UIImage(systemName: "bubble.left.and.bubble.right.fill"), tag: 0),
                UITabBarItem(title: "Calls", image: UIImage(systemName: "phone.fill"), tag: 1),
                UITabBarItem(title: "Profile", image: UIImage(systemName: "person.crop.circle.fill"), tag: 2),
            ]
            viewControllers = items.map { item in
                let page = UIViewController()
                page.view.backgroundColor = .clear
                page.view.isUserInteractionEnabled = false
                page.tabBarItem = item
                return page
            }
        }

        func update(selected: Int, chatsBadge: Int, callsBadge: Int, avatarData: Data?) {
            guard let pages = viewControllers, pages.count == 3 else { return }
            pages[0].tabBarItem.badgeValue = Self.badge(chatsBadge)
            pages[1].tabBarItem.badgeValue = Self.badge(callsBadge)
            let key = avatarData?.hashValue ?? 0
            if avatarKey != key {
                avatarKey = key
                pages[2].tabBarItem.image = Self.profileImage(avatarData)
            }
            if selectedIndex != selected { selectedIndex = selected }
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            onSelect?(viewController.tabBarItem.tag)
        }

        private static func badge(_ count: Int) -> String? {
            count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
        }

        /// Same icon as the iPhone Profile tab: the avatar cropped to a
        /// circle, or the person symbol when there isn't one.
        private static func profileImage(_ data: Data?) -> UIImage? {
            guard let data, let src = DecodedImageCache.image(for: data) else {
                return UIImage(systemName: "person.crop.circle.fill")
            }
            let side: CGFloat = 28
            let size = CGSize(width: side, height: side)
            return UIGraphicsImageRenderer(size: size).image { _ in
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
                let ratio = max(side / src.size.width, side / src.size.height)
                src.draw(in: CGRect(x: (side - src.size.width * ratio) / 2, y: (side - src.size.height * ratio) / 2,
                                    width: src.size.width * ratio, height: src.size.height * ratio))
            }.withRenderingMode(.alwaysOriginal)
        }
    }
}
