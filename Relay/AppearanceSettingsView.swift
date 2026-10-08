//
//  AppearanceSettingsView.swift
//  Relay
//

import PhotosUI
import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @Environment(ChatAppearance.self) private var appearance
    @State private var wallpaperPhoto: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                previewCard
                themesSection
                wallpaperSection
                bubbleSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: wallpaperPhoto) { _, item in loadPhoto(item) }
    }

    // MARK: - Preview

    private var previewCard: some View {
        ZStack {
            appearance.background
            VStack(alignment: .leading, spacing: 8) {
                previewBubble("Hey! Love the new look 👀", outgoing: false)
                previewBubble("Right? Custom wallpapers now.", outgoing: true)
                previewBubble("Looks amazing 🔥", outgoing: false)
            }
            .padding(16)
        }
        .frame(height: 200)
        .clipShape(.rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private func previewBubble(_ text: String, outgoing: Bool) -> some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                outgoing
                    ? AnyShapeStyle(appearance.bubbleGradient)
                    : AnyShapeStyle(Material.regularMaterial),
                in: .rect(cornerRadius: 16)
            )
            .foregroundStyle(outgoing ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    // MARK: - Themes

    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Themes")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ChatAppearance.themes) { theme in
                        ThemeCard(theme: theme, isSelected: isThemeSelected(theme)) {
                            withAnimation(.spring(duration: 0.3)) {
                                appearance.applyTheme(theme)
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
            }
        }
    }

    private func isThemeSelected(_ theme: AppearanceTheme) -> Bool {
        appearance.wallpaper == theme.wallpaper && appearance.bubbleTintHex == theme.bubbleKey
    }

    // MARK: - Wallpaper

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Wallpaper")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(WallpaperStyle.allCases.filter { $0 != .photo }) { style in
                        wallpaperSwatch(for: style)
                    }
                    photoWallpaperSwatch
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
            }
        }
    }

    private func wallpaperSwatch(for style: WallpaperStyle) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { appearance.wallpaper = style }
        } label: {
            VStack(spacing: 6) {
                swatchBackground(style)
                    .frame(width: 72, height: 110)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                appearance.wallpaper == style ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    }
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                Text(style.title)
                    .font(.caption2)
                    .foregroundStyle(appearance.wallpaper == style ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func swatchBackground(_ style: WallpaperStyle) -> some View {
        if style == .none {
            ZStack {
                Color(.secondarySystemGroupedBackground)
                Image(systemName: "slash.circle").foregroundStyle(.tertiary).font(.title2)
            }
        } else if let gradient = style.gradient {
            gradient
        } else {
            Color(.secondarySystemGroupedBackground)
        }
    }

    private var photoWallpaperSwatch: some View {
        PhotosPicker(selection: $wallpaperPhoto, matching: .images) {
            VStack(spacing: 6) {
                ZStack {
                    if appearance.wallpaper == .photo, let ui = appearance.photoImage {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemGroupedBackground)
                        VStack(spacing: 4) {
                            Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 72, height: 110)
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            appearance.wallpaper == .photo ? Color.accentColor : Color.clear,
                            lineWidth: 3
                        )
                }
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                Text("Photo")
                    .font(.caption2)
                    .foregroundStyle(appearance.wallpaper == .photo ? Color.accentColor : .secondary)
            }
        }
    }

    // MARK: - Bubble gradient

    private var bubbleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Bubble Style")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    bubbleGradientSwatch(pair: nil)
                    ForEach(Array(ChatAppearance.bubblePalette.enumerated()), id: \.offset) { _, pair in
                        bubbleGradientSwatch(pair: pair)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
            }
        }
    }

    private func bubbleGradientSwatch(pair: (String, String)?) -> some View {
        let key: String? = pair.map { "\($0.0)-\($0.1)" }
        let isSelected = appearance.bubbleTintHex == key
        let gradient: AnyShapeStyle = {
            if let pair, let a = Color(hex: pair.0), let b = Color(hex: pair.1) {
                return AnyShapeStyle(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            return AnyShapeStyle(Color.accentColor)
        }()

        let label: String = {
            guard let pair else { return "Default" }
            switch "\(pair.0)-\(pair.1)" {
            case "0A84FF-5E5CE6": return "Blue"
            case "30D158-00C7BE": return "Green"
            case "BF5AF2-FF2D55": return "Purple"
            case "FF3B30-FF9500": return "Red"
            case "FF9500-FFCC00": return "Amber"
            case "34C759-0A84FF": return "Ocean"
            case "2C2C2E-48484A": return "Graphite"
            case "FF2D55-FF6B35": return "Coral"
            default: return "Custom"
            }
        }()

        return Button {
            withAnimation(.spring(duration: 0.3)) { appearance.bubbleTintHex = key }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Capsule()
                        .fill(gradient)
                        .frame(width: 60, height: 34)
                    if pair == nil {
                        Text("A")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Color.primary : Color.clear, lineWidth: 2.5)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else { return }
            appearance.setPhoto(data)
        }
    }
}

// MARK: - Theme card

private struct ThemeCard: View {
    let theme: AppearanceTheme
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    wallpaperFill
                        .frame(width: 90, height: 130)
                    // Mini bubble preview
                    RoundedRectangle(cornerRadius: 10)
                        .fill(bubbleGradient)
                        .frame(width: 54, height: 22)
                        .padding(8)
                }
                Text(theme.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var wallpaperFill: some View {
        if let gradient = theme.wallpaper.gradient {
            gradient
        } else {
            Color(.secondarySystemGroupedBackground)
        }
    }

    private var bubbleGradient: LinearGradient {
        let parts = theme.bubbleKey.split(separator: "-", maxSplits: 1).map(String.init)
        let a = parts.count > 0 ? Color(hex: parts[0]) : nil
        let b = parts.count > 1 ? Color(hex: parts[1]) : nil
        return LinearGradient(
            colors: [a ?? .accentColor, b ?? a ?? .accentColor],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}
