//
//  DesignSystem.swift
//  Relay
//
//  The single source of truth for spacing, radii, sizing, motion, and the
//  shared building-block components used across the app. Screens should reach
//  for these tokens instead of hard-coding magic numbers so the UI stays
//  cohesive. Purely presentational — no state, no dependencies beyond SwiftUI.
//
//  Glass lives in GlassCompat.swift; chat wallpaper/bubble theming lives in
//  ChatAppearance.swift. This file is the neutral chrome vocabulary shared by
//  every screen (lists, settings, sheets, rows, badges).
//

import SwiftUI

/// Namespaced design tokens. Access as `DS.Spacing.md`, `DS.Radius.card`, etc.
enum DS {

    // MARK: Spacing

    /// A consistent 4-point spacing scale. Prefer these over literals.
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

    /// Corner radii keyed by the surface they belong to, so the same kind of
    /// element always uses the same curvature.
    enum Radius {
        static let control: CGFloat = 10   // small buttons, chips-as-rects
        static let field: CGFloat = 12     // text fields, small tiles
        static let card: CGFloat = 16      // cards, grouped row backgrounds
        static let bubble: CGFloat = 20    // chat bubbles
        static let sheet: CGFloat = 24     // floating bars, large sheets
    }

    // MARK: Avatar sizes

    /// Standard avatar diameters. Rows should pick one of these, not a literal.
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

    /// Shared animation presets so transitions feel like one app.
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

/// A rounded count pill (unread messages, archived count, etc.). One badge for
/// the whole app so counts always look the same. `tint` fills the pill; text is
/// always high-contrast white for legibility on colored fills.
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

/// A selectable capsule chip (filters, quick toggles). Consolidates the
/// previously ad-hoc chip styling into one look.
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

/// The branded avatar for the official, read-only "Relay" system chat — an
/// accent-gradient disc with the relay glyph. Distinct from user avatars.
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

/// A compact inline error chip (icon + message on a soft red fill). Shared so
/// error states read the same wherever they surface.
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

/// The small circular "edit" affordance overlaid on the bottom-trailing corner
/// of an editable avatar. One look everywhere an avatar can be changed.
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

/// A grouped-list section header with consistent typography and casing.
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
    /// Wraps a row's content in the standard rounded card surface used for
    /// grouped/floating rows, so every "card" shares one radius and fill.
    func dsCard(_ fill: some ShapeStyle = AnyShapeStyle(.dsCard),
                cornerRadius: CGFloat = DS.Radius.card) -> some View {
        background(fill, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Standard horizontal screen padding for content outside of `List`.
    func dsScreenPadding() -> some View {
        padding(.horizontal, DS.Spacing.lg)
    }
}
