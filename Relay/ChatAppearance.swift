//
//  ChatAppearance.swift
//  Relay
//
//  Local, device-only chat personalization: a wallpaper behind the message
//  list and the outgoing-bubble gradient. Nothing here is shared or synced —
//  it's purely how *this* device renders chats.
//

import SwiftUI
import UIKit

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case none, sunset, ocean, forest, twilight, rose, graphite, photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .twilight: "Twilight"
        case .rose: "Rose"
        case .graphite: "Graphite"
        case .photo: "Photo"
        }
    }

    var gradient: LinearGradient? {
        let stops: [String]? = switch self {
        case .sunset:   ["FF7E5F", "FEB47B"]
        case .ocean:    ["2193B0", "6DD5ED"]
        case .forest:   ["134E5E", "71B280"]
        case .twilight: ["4B2E83", "9D50BB"]
        case .rose:     ["C94B8F", "F6A5C0"]
        case .graphite: ["1C1C1E", "3A3A3C"]
        case .none, .photo: nil
        }
        guard let stops, let a = Color(hex: stops[0]), let b = Color(hex: stops[1]) else { return nil }
        return LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
    }
}

/// A curated theme pairing a wallpaper with a matching bubble gradient.
struct AppearanceTheme: Identifiable {
    let id: String
    let name: String
    let wallpaper: WallpaperStyle
    let bubbleKey: String  // "RRGGBB-RRGGBB"
}

@Observable
final class ChatAppearance {
    /// Curated bubble gradient palette stored as "startHex-endHex". nil = accent.
    static let bubblePalette: [(String, String)] = [
        ("0A84FF", "5E5CE6"),  // blue → indigo
        ("30D158", "00C7BE"),  // green → teal
        ("BF5AF2", "FF2D55"),  // purple → pink
        ("FF3B30", "FF9500"),  // red → amber
        ("FF9500", "FFCC00"),  // amber → gold
        ("34C759", "0A84FF"),  // green → blue
        ("2C2C2E", "48484A"),  // graphite
        ("FF2D55", "FF6B35"),  // coral-red
    ]

    /// Curated wallpaper + bubble combos — bubble contrasts against the wallpaper.
    static let themes: [AppearanceTheme] = [
        AppearanceTheme(id: "ocean",    name: "Ocean",    wallpaper: .ocean,    bubbleKey: "30D158-00C7BE"),  // green on blue
        AppearanceTheme(id: "forest",   name: "Forest",   wallpaper: .forest,   bubbleKey: "FF9500-FFCC00"),  // amber on dark green
        AppearanceTheme(id: "twilight", name: "Twilight", wallpaper: .twilight, bubbleKey: "00C7BE-30D158"),  // teal on purple
        AppearanceTheme(id: "sunset",   name: "Sunset",   wallpaper: .sunset,   bubbleKey: "BF5AF2-5E5CE6"),  // purple on orange
        AppearanceTheme(id: "rose",     name: "Rose",     wallpaper: .rose,     bubbleKey: "0A84FF-5E5CE6"),  // blue on pink
        AppearanceTheme(id: "dark",     name: "Dark",     wallpaper: .graphite, bubbleKey: "0A84FF-5E5CE6"),  // blue on graphite
    ]

    var wallpaper: WallpaperStyle {
        didSet { defaults.set(wallpaper.rawValue, forKey: Keys.wallpaper) }
    }
    /// Stored as "RRGGBB-RRGGBB" for a two-stop gradient; nil = accent color.
    var bubbleTintHex: String? {
        didSet { defaults.set(bubbleTintHex, forKey: Keys.bubbleTint) }
    }
    private(set) var photoData: Data?

    private let defaults = UserDefaults.standard
    private enum Keys { static let wallpaper = "chat.wallpaper", bubbleTint = "chat.bubbleTint" }

    init() {
        wallpaper = WallpaperStyle(rawValue: defaults.string(forKey: Keys.wallpaper) ?? "") ?? .none
        bubbleTintHex = defaults.string(forKey: Keys.bubbleTint)
        photoData = try? Data(contentsOf: Self.photoURL)
    }

    func applyTheme(_ theme: AppearanceTheme) {
        wallpaper = theme.wallpaper
        bubbleTintHex = theme.bubbleKey
    }

    /// Parses the stored hex key into gradient start + end colors.
    private func parsedStops() -> (Color, Color) {
        guard let hex = bubbleTintHex else { return (.accentColor, .accentColor) }
        let parts = hex.split(separator: "-", maxSplits: 1).map(String.init)
        let a = parts.count > 0 ? Color(hex: parts[0]) : nil
        let b = parts.count > 1 ? Color(hex: parts[1]) : nil
        let first = a ?? .accentColor
        let second = b ?? first
        return (first, second)
    }

    /// Flat outgoing-bubble color (first gradient stop).
    var bubbleTint: Color { parsedStops().0 }

    /// Diagonal gradient for outgoing bubbles.
    var bubbleGradient: LinearGradient {
        let (a, b) = parsedStops()
        return LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func setPhoto(_ data: Data?) {
        photoData = data
        if let data {
            try? data.write(to: Self.photoURL, options: .atomic)
            wallpaper = .photo
        } else {
            try? FileManager.default.removeItem(at: Self.photoURL)
            if wallpaper == .photo { wallpaper = .none }
        }
    }

    /// Subtle tint for non-chat views (chat list, calls, settings).
    @ViewBuilder
    var appBackground: some View {
        switch wallpaper {
        case .none:
            EmptyView()
        case .photo:
            if let photoData, let ui = UIImage(data: photoData) {
                Image(uiImage: ui).resizable().scaledToFill().opacity(0.08)
            }
        default:
            if let gradient = wallpaper.gradient {
                gradient.opacity(0.07)
            }
        }
    }

    @ViewBuilder
    var background: some View {
        switch wallpaper {
        case .photo:
            if let photoData, let ui = UIImage(data: photoData) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Color(.systemBackground)
            }
        default:
            if let gradient = wallpaper.gradient {
                gradient
            } else {
                Color(.systemBackground)
            }
        }
    }

    private static var photoURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chat-wallpaper.jpg")
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
