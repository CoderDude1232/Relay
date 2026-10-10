//
//  DesignSystem.swift
//  Relay
//
//  Spacing, radius, sizing and motion tokens plus small shared components.
//  Glass is in GlassCompat.swift; chat theming is in ChatAppearance.swift.
//

import SwiftUI

/// Namespaced design tokens. Access as `DS.Spacing.md`, `DS.Radius.card`, etc.
enum DS {

    // MARK: Spacing

    /// 4-point spacing scale.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: Corner radius

    enum Radius {
        static let control: CGFloat = 10   // small buttons, chips-as-rects
        static let field: CGFloat = 12     // text fields, small tiles
        static let card: CGFloat = 16      // cards, grouped row backgrounds
        static let bubble: CGFloat = 20    // chat bubbles
        static let sheet: CGFloat = 24     // floating bars, large sheets
    }

    // MARK: Avatar sizes

    enum Avatar {
        static let xs: CGFloat = 28   // inline contact rows
        static let sm: CGFloat = 36   // compact lists
        static let md: CGFloat = 44   // search results, sheets
        static let lg: CGFloat = 56   // conversation list
        static let xl: CGFloat = 72   // headers
        static let xxl: CGFloat = 96  // profile / contact card
    }

    // MARK: Icon sizes

    enum Icon {
        static let sm: CGFloat = 13
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
    }

    // MARK: Motion

    enum Motion {
        /// Snappy spring for selection, toggles, badge count changes.
        static let snappy: Animation = .spring(duration: 0.22)
        /// Softer spring for content that moves a longer distance.
        static let smooth: Animation = .spring(duration: 0.35)
        /// Simple ease for scroll-to and cross-fades.
        static let quick: Animation = .easeInOut(duration: 0.15)
    }

    // MARK: Opacity

    enum Opacity {
        static let subtleFill: Double = 0.10   // tinted row/selection backgrounds
        static let hairlineFill: Double = 0.07  // pinned row wash, wallpaper tint
    }
}

// MARK: - Semantic colors

extension ShapeStyle where Self == Color {
    /// Hairline separators that adapt to light/dark.
    static var dsSeparator: Color { Color(.separator) }
    /// The recessed background behind grouped content.
    static var dsGroupedBackground: Color { Color(.systemGroupedBackground) }
    /// A raised card/surface fill.
    static var dsCard: Color { Color(.secondarySystemBackground) }
}

// MARK: - Shared components

/// A rounded count pill (unread, archived, etc.). Text is always white.
struct CountBadge: View {
    let count: Int
    var tint: Color = .accentColor
    var countsDown: Bool = false

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Spacing.sm - 1)
            .padding(.vertical, DS.Spacing.xxs + 1)
            .background(tint, in: .capsule)
            .contentTransition(.numericText(countsDown: countsDown))
            .animation(DS.Motion.smooth, value: count)
            .accessibilityLabel("\(count)")
    }
}

/// A selectable capsule chip (filters, quick toggles).
struct Pill: View {
    let title: String
    var isSelected: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, DS.Spacing.md + 2)
                .padding(.vertical, DS.Spacing.sm - 2)
                .foregroundStyle(isSelected ? .white : .primary)
                .background {
                    Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
                }
                .glassCompat(in: .capsule)
                .animation(DS.Motion.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Avatar for the official, read-only "Relay" system chat.
struct RelayOfficialAvatar: View {
    var size: CGFloat = 54

    var body: some View {
        Circle()
            .fill(Color.accentColor.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Relay")
    }
}

/// A compact inline error chip (icon and message on a soft red fill).
struct InlineErrorBanner: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "xmark.circle.fill")
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color.red.opacity(0.9))
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(Color.red.opacity(0.12), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

/// Small circular edit badge for the bottom-trailing corner of an avatar.
struct AvatarEditBadge: View {
    var systemImage: String = "camera.fill"
    var diameter: CGFloat = 24

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: diameter * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Color.accentColor, in: .circle)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// A grouped-list section header.
struct DSSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

// MARK: - Card row modifier

extension View {
    /// Wraps a row's content in the standard rounded card surface.
    func dsCard(_ fill: some ShapeStyle = AnyShapeStyle(.dsCard),
                cornerRadius: CGFloat = DS.Radius.card) -> some View {
        background(fill, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Standard horizontal screen padding for content outside of `List`.
    func dsScreenPadding() -> some View {
        padding(.horizontal, DS.Spacing.lg)
    }
}
