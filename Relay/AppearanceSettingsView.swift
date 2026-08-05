//
//  AppearanceSettingsView.swift
//  Relay
//
//  Picks the chat wallpaper and outgoing-bubble color, with a live preview.
//

import PhotosUI
import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @Environment(ChatAppearance.self) private var appearance
    @State private var wallpaperPhoto: PhotosPickerItem?

    var body: some View {
        List {
            Section {
                preview
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Wallpaper") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(WallpaperStyle.allCases.filter { $0 != .photo }) { style in
                            swatch(for: style)
                        }
                        photoSwatch
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section("Bubble Color") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        bubbleDot(hex: nil) // accent default
                        ForEach(ChatAppearance.bubblePalette, id: \.self) { hex in
                            bubbleDot(hex: hex)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .navigationTitle("Chat Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: wallpaperPhoto) { _, item in loadPhoto(item) }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            appearance.background
            VStack(alignment: .leading, spacing: 8) {
                bubble("Hey! Love the new look 👀", outgoing: false)
                bubble("Right? Custom wallpapers now.", outgoing: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(height: 160)
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func bubble(_ text: String, outgoing: Bool) -> some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                outgoing ? AnyShapeStyle(appearance.bubbleTint) : AnyShapeStyle(.fill.secondary),
                in: .rect(cornerRadius: 16)
            )
            .foregroundStyle(outgoing ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    // MARK: - Swatches

    private func swatch(for style: WallpaperStyle) -> some View {
        Button {
            appearance.wallpaper = style
        } label: {
            swatchFill(style)
                .frame(width: 56, height: 84)
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.tint, lineWidth: appearance.wallpaper == style ? 3 : 0)
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func swatchFill(_ style: WallpaperStyle) -> some View {
        if style == .none {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: "slash.circle").foregroundStyle(.secondary)
            }
        } else if let gradient = style.gradient {
            gradient
        } else {
            Color(.secondarySystemBackground)
        }
    }

    private var photoSwatch: some View {
        PhotosPicker(selection: $wallpaperPhoto, matching: .images) {
            ZStack {
                if appearance.wallpaper == .photo, let data = appearance.photoData, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 84)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint, lineWidth: appearance.wallpaper == .photo ? 3 : 0)
            }
        }
    }

    private func bubbleDot(hex: String?) -> some View {
        let color = hex.flatMap { Color(hex: $0) } ?? .accentColor
        let selected = appearance.bubbleTintHex == hex
        return Button {
            appearance.bubbleTintHex = hex
        } label: {
            Circle()
                .fill(color)
                .frame(width: 40, height: 40)
                .overlay {
                    if hex == nil {
                        Text("A").font(.caption.bold()).foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle().strokeBorder(.primary, lineWidth: selected ? 2.5 : 0)
                }
        }
        .buttonStyle(.plain)
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
