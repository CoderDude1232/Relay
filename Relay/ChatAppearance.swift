//
//  ChatAppearance.swift
//  Relay
//
//  Local, device-only chat personalization: a wallpaper behind the message
//  list and the outgoing-bubble color. Nothing here is shared or synced —
//  it's purely how *this* device renders chats. Persisted in UserDefaults
//  (and a file for a custom wallpaper photo).
//

import SwiftUI
import UIKit

/// A chat wallpaper: none, one of a few built-in gradients, or a custom photo.
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

    /// The two-stop gradient for a preset, or nil for `.none`/`.photo`.
    var gradient: LinearGradient? {
        let stops: [String]? = switch self {
        case .sunset: ["FF7E5F", "FEB47B"]
        case .ocean: ["2193B0", "6DD5ED"]
        case .forest: ["134E5E", "71B280"]
        case .twilight: ["4B2E83", "9D50BB"]
        case .rose: ["C94B8F", "F6A5C0"]
        case .graphite: ["232526", "414345"]
        case .none, .photo: nil
        }
        guard let stops, let a = Color(hex: stops[0]), let b = Color(hex: stops[1]) else { return nil }
        return LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
    }
}

@Observable
final class ChatAppearance {
    /// Preset bubble colors offered in the picker (hex). `nil` = app accent.
    static let bubblePalette: [String] = [
        "0A84FF", "30D158", "5E5CE6", "FF375F", "FF9F0A", "BF5AF2", "64D2FF", "8E8E93",
    ]

    var wallpaper: WallpaperStyle {
        didSet { defaults.set(wallpaper.rawValue, forKey: Keys.wallpaper) }
    }
    /// Outgoing-bubble color as a hex string; nil uses the system accent.
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

    /// The outgoing bubble fill.
    var bubbleTint: Color {
        bubbleTintHex.flatMap { Color(hex: $0) } ?? .accentColor
    }

    /// Stores (or clears) the custom wallpaper photo and selects/deselects it.
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

    /// The full-bleed background view for the current wallpaper.
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
    /// Builds a color from a 6-digit RRGGBB hex string (with or without `#`).
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
