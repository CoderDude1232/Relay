//
//  AppearanceSettingsView.swift
//  Relay
//

import PhotosUI
import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    /// Set when opened from a chat: changes apply to that chat only.
    var chatId: String? = nil

    @Environment(ChatAppearance.self) private var environmentAppearance
    @State private var wallpaperPhoto: PhotosPickerItem?
    @State private var showingSupporter = false
    private var supporter = Supporter.shared

    /// The app's theme (the environment may hold a chat's).
    private var app: ChatAppearance {
        environmentAppearance.scope == nil ? environmentAppearance : (ChatAppearance.app ?? environmentAppearance)
    }

    /// What's shown: the chat's own theme, or the one it inherits.
    private var appearance: ChatAppearance {
        chatId.flatMap { app.theme(forChat: $0) } ?? app
    }

    private var chatHasOwnTheme: Bool { chatId.map { app.themedChats.contains($0) } ?? false }

    /// Applies a change: to the chat (giving it its own theme first) or the app.
    private func edit(_ change: (ChatAppearance) -> Void) {
        withAnimation(.spring(duration: 0.3)) {
            if let chatId { change(app.startTheme(forChat: chatId)) } else { change(app) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if chatId != nil { chatThemeHeader }
                previewCard
                themesSection
                wallpaperSection
                bubbleSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background {
            if !appearance.hasWallpaper { Color(.systemGroupedBackground).ignoresSafeArea() }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle(chatId == nil ? "Appearance" : "Chat Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: wallpaperPhoto) { _, item in loadPhoto(item) }
        .sheet(isPresented: $showingSupporter) { SupporterView() }
    }

    // MARK: - This chat

    private var chatThemeHeader: some View {
        HStack(spacing: 12) {
            Text(chatHasOwnTheme
                 ? "This chat has its own theme."
                 : "This chat uses your app theme. Changes here apply to this chat only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if chatHasOwnTheme, let chatId {
                Button("Use App Theme") {
                    withAnimation(.spring(duration: 0.3)) { app.removeTheme(forChat: chatId) }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
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
                outgoing ? appearance.bubbleTint
                    : appearance.wallpaper == .none ? Color(.secondarySystemBackground) : Color(.tertiarySystemBackground),
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
                            edit { $0.applyTheme(theme) }
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
                    ForEach(WallpaperStyle.allCases.filter { style in
                        style != .photo && (!style.isSupporterOnly || supporter.isOffered || appearance.wallpaper == style)
                    }) { style in
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
        let locked = style.isSupporterOnly && !supporter.isActive && appearance.wallpaper != style
        return Button {
            if locked { showingSupporter = true } else { edit { $0.wallpaper = style } }
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
                    .overlay(alignment: .topTrailing) {
                        if style.isSupporterOnly {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(.pink.gradient, in: .circle)
                                .padding(6)
                        }
                    }
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                Text(style.title)
                    .font(.caption2)
                    .foregroundStyle(appearance.wallpaper == style ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.isSupporterOnly ? "\(style.title), supporter wallpaper" : style.title)
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

    // MARK: - Bubble colour

    private var bubbleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Bubble Colour")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    bubbleSwatch(name: "Default", key: nil, color: .accentColor)
                    ForEach(ChatAppearance.bubblePalette, id: \.hex) { entry in
                        bubbleSwatch(name: entry.name, key: ChatAppearance.bubbleKey(entry.hex),
                                     color: Color(hex: entry.hex) ?? .accentColor)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }

    private func bubbleSwatch(name: String, key: String?, color: Color) -> some View {
        let isSelected = appearance.bubbleTintHex == key
        return Button {
            edit { $0.bubbleTintHex = key }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 40, height: 40)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(3)
                    .overlay {
                        Circle().strokeBorder(isSelected ? color : .clear, lineWidth: 2)
                    }
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) bubbles")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            edit { $0.setPhoto(data) }
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
            VStack(spacing: 6) {
                ZStack {
                    wallpaperFill
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule()
                            .fill(Color(.tertiarySystemBackground))
                            .frame(width: 46, height: 16)
                        Capsule()
                            .fill(bubbleColor)
                            .frame(width: 52, height: 16)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Capsule()
                            .fill(Color(.tertiarySystemBackground))
                            .frame(width: 34, height: 16)
                    }
                    .padding(10)
                }
                .frame(width: 90, height: 120)
                .clipShape(.rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(isSelected ? bubbleColor : Color.primary.opacity(0.08),
                                      lineWidth: isSelected ? 3 : 1)
                }
                Text(theme.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var wallpaperFill: some View {
        if let gradient = theme.wallpaper.gradient {
            gradient
        } else {
            Color(.secondarySystemGroupedBackground)
        }
    }

    private var bubbleColor: Color {
        theme.bubbleKey.flatMap { Color(hex: String($0.prefix(6))) } ?? .accentColor
    }
}
