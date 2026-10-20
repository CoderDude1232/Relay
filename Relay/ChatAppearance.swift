//
//  ChatAppearance.swift
//  Relay
//
//  Device-local chat personalization (wallpaper and outgoing-bubble colour).
//  Nothing here is shared or synced.
//

import CoreImage
import SwiftUI
import UIKit

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case none, sunset, ocean, forest, twilight, rose, graphite, photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .sunset: "Peach"
        case .ocean: "Sky"
        case .forest: "Mint"
        case .twilight: "Lavender"
        case .rose: "Rose"
        case .graphite: "Graphite"
        case .photo: "Photo"
        }
    }

    /// Soft tints rather than full-strength colour, so bubbles (white or
    /// coloured) sit on them cleanly: pale in light mode, deep in dark mode.
    /// (Case names are the stored values from before the rename.)
    private var stops: (light: [String], dark: [String])? {
        switch self {
        case .ocean:    (["EAF3FD", "D6E7F9"], ["0A1520", "0F2236"])
        case .forest:   (["E9F6EF", "D5EEE1"], ["0A1812", "0F241B"])
        case .twilight: (["F0ECFB", "E1D9F7"], ["130E20", "1D1630"])
        case .sunset:   (["FDF0E8", "F9E0D2"], ["1F130D", "2B1A11"])
        case .rose:     (["FCEBF1", "F6D8E3"], ["1F0D14", "2C131E"])
        case .graphite: (["EFEFF2", "DEDEE3"], ["121214", "1D1D21"])
        case .none, .photo: nil
        }
    }

    var gradient: LinearGradient? {
        guard let stops else { return nil }
        let colors = zip(stops.light, stops.dark).compactMap { light, dark -> Color? in
            guard let l = UIColor(relayHex: light), let d = UIColor(relayHex: dark) else { return nil }
            return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// A curated theme pairing a wallpaper with a matching bubble gradient.
struct AppearanceTheme: Identifiable {
    let id: String
    let name: String
    let wallpaper: WallpaperStyle
    let bubbleKey: String?  // "RRGGBB-RRGGBB"; nil = the app accent
}

@Observable
final class ChatAppearance {
    /// Flat bubble colours, each dark enough for white text. Stored as
    /// "RRGGBB-RRGGBB" (both stops equal) so older builds and the Watch,
    /// which read two stops, still show the same colour.
    static let bubblePalette: [(name: String, hex: String)] = [
        ("Blue", "0A7AFF"),
        ("Indigo", "5856D6"),
        ("Purple", "8E4FE0"),
        ("Pink", "E0457B"),
        ("Red", "E5484D"),
        ("Orange", "EE7A1F"),
        ("Green", "1F9D55"),
        ("Teal", "0E8F99"),
        ("Graphite", "48484A"),
    ]

    static func bubbleKey(_ hex: String) -> String { "\(hex)-\(hex)" }

    /// A wallpaper with a bubble from the same colour family.
    static let themes: [AppearanceTheme] = [
        AppearanceTheme(id: "sky",      name: "Sky",      wallpaper: .ocean,    bubbleKey: bubbleKey("0A7AFF")),
        AppearanceTheme(id: "mint",     name: "Mint",     wallpaper: .forest,   bubbleKey: bubbleKey("1F9D55")),
        AppearanceTheme(id: "lavender", name: "Lavender", wallpaper: .twilight, bubbleKey: bubbleKey("8E4FE0")),
        AppearanceTheme(id: "peach",    name: "Peach",    wallpaper: .sunset,   bubbleKey: bubbleKey("EE7A1F")),
        AppearanceTheme(id: "rose",     name: "Rose",     wallpaper: .rose,     bubbleKey: bubbleKey("E0457B")),
        AppearanceTheme(id: "graphite", name: "Graphite", wallpaper: .graphite, bubbleKey: nil),
    ]

    var wallpaper: WallpaperStyle {
        didSet { defaults.set(wallpaper.rawValue, forKey: Keys.wallpaper) }
    }
    /// Stored as "RRGGBB-RRGGBB" (equal stops); nil = accent color.
    var bubbleTintHex: String? {
        didSet { defaults.set(bubbleTintHex, forKey: Keys.bubbleTint) }
    }
    private(set) var photoData: Data? {
        didSet {
            photoImage = Self.decode(photoData)
        softenedPhoto = Self.soften(photoImage)
            softenedPhoto = Self.soften(photoImage)
        }
    }
    /// `photoData` decoded once, so chat backgrounds don't re-decode the
    /// full-size photo on every render.
    private(set) var photoImage: UIImage?
    /// A small, blurred copy of the photo for behind lists and pages.
    private(set) var softenedPhoto: UIImage?

    private let defaults = UserDefaults.standard
    private enum Keys { static let wallpaper = "chat.wallpaper", bubbleTint = "chat.bubbleTint" }

    init() {
        wallpaper = WallpaperStyle(rawValue: defaults.string(forKey: Keys.wallpaper) ?? "") ?? .none
        bubbleTintHex = defaults.string(forKey: Keys.bubbleTint)
        photoData = try? Data(contentsOf: Self.photoURL)
        photoImage = Self.decode(photoData)
        if photoData != nil { Self.protectPhotoFile() } // files saved by older builds
    }

    /// Excludes the wallpaper photo from backups and sets its protection class.
    private static func protectPhotoFile() {
        var url = photoURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// Downscaled, then blurred once, so pages don't blur a full-size photo
    /// on every render.
    private static func soften(_ image: UIImage?) -> UIImage? {
        guard let image, let small = image.preparingThumbnail(of: CGSize(width: 240, height: 240 * image.size.height / max(image.size.width, 1))),
              let input = CIImage(image: small) else { return nil }
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: input.extent)
        guard let cg = CIContext().createCGImage(blurred, from: input.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func decode(_ data: Data?) -> UIImage? {
        guard let data, let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    func applyTheme(_ theme: AppearanceTheme) {
        wallpaper = theme.wallpaper
        bubbleTintHex = theme.bubbleKey
    }

    private func parsedStops() -> (Color, Color) {
        guard let hex = bubbleTintHex else { return (.accentColor, .accentColor) }
        let parts = hex.split(separator: "-", maxSplits: 1).map(String.init)
        let a = parts.count > 0 ? Color(hex: parts[0]) : nil
        let b = parts.count > 1 ? Color(hex: parts[1]) : nil
        let first = a ?? .accentColor
        let second = b ?? first
        return (first, second)
    }

    /// The outgoing bubble colour. Bubbles are flat: a two-colour choice
    /// from an older build uses its first colour.
    var bubbleTint: Color { parsedStops().0 }

    func setPhoto(_ data: Data?) {
        photoData = data
        if let data {
            // Until-first-unlock, not complete: a VoIP push can launch the app
            // in the background while the device is locked.
            try? data.write(to: Self.photoURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            Self.protectPhotoFile()
            wallpaper = .photo
        } else {
            try? FileManager.default.removeItem(at: Self.photoURL)
            if wallpaper == .photo { wallpaper = .none }
        }
    }

    /// Whether a wallpaper is in use (a photo wallpaper whose file is gone isn't).
    var hasWallpaper: Bool {
        switch wallpaper {
        case .none: false
        case .photo: photoImage != nil
        default: true
        }
    }

    /// Behind a chat: the wallpaper itself.
    @ViewBuilder
    var background: some View {
        switch wallpaper {
        case .photo:
            if let ui = photoImage {
                WindowAnchoredImage(image: ui)
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

    /// Behind lists and pages (chat list, calls, profile): the same theme,
    /// with a photo softened so text on it stays readable.
    @ViewBuilder
    var pageBackground: some View {
        if wallpaper == .photo, let soft = softenedPhoto {
            WindowAnchoredImage(image: soft)
                .overlay(Color(.systemBackground).opacity(0.55))
        } else {
            background
        }
    }

    private static var photoURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chat-wallpaper.jpg")
    }
}

extension UIColor {
    convenience init?(relayHex hex: String) {
        guard s6(hex) != nil, let v = UInt32(s6(hex)!, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

private func s6(_ hex: String) -> String? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    return s.count == 6 ? s : nil
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

/// A photo filling the whole window, of which this view shows its own part:
/// side-by-side iPad columns show one continuous picture, not two crops.
struct WindowAnchoredImage: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let size = Self.windowSize ?? geo.size
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .offset(x: -frame.minX, y: -frame.minY)
        }
        .clipped()
    }

    /// Read when laid out, so it follows rotation and window resizing.
    private static var windowSize: CGSize? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.bounds.size
    }
}
