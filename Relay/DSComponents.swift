//
//  DSComponents.swift
//  Relay
//
//  The building blocks screens are made from, so every page looks like one
//  app: grouped cards on the grouped background, coloured icon tiles, a pink
//  main button, and Bricolage Grotesque headlines with one pink word. Tokens
//  are in DesignSystem.swift.
//

import SwiftUI

// MARK: - Type

extension Font {
    /// Headlines: Bricolage Grotesque (bundled, OFL), following Dynamic Type.
    static func dsDisplay(_ size: CGFloat = 34) -> Font {
        .custom("Bricolage Grotesque", size: size, relativeTo: .largeTitle).weight(.heavy)
    }
}

// MARK: - Page

/// A page's headline: left-aligned, with an optional pink word at the end
/// ("Find your" + "people"), and a line underneath.
struct DSHeadline: View {
    let title: String
    var accent: String? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Group {
                if let accent {
                    Text("\(title) \(Text(accent).foregroundStyle(Color.accentColor))")
                } else {
                    Text(title)
                }
            }
            .font(.dsDisplay())
            .tracking(-0.5)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A full page: the grouped background, a scrolling column of content and,
/// optionally, a button pinned to the bottom.
struct DSPage<Content: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    content()
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.vertical, DS.Spacing.md)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer()
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.md)
                .frame(maxWidth: 520)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

extension DSPage where Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, footer: { EmptyView() })
    }
}

// MARK: - Groups and rows

/// A grouped card: its rows with hairlines between them.
struct DSGroup<Content: View>: View {
    var label: String? = nil
    var footer: String? = nil
    /// Where hairlines start: past the icon tiles, or at the text for rows without them.
    var separatorInset: CGFloat = 56
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let label {
                Text(label.uppercased())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, DS.Spacing.lg)
            }
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(Color(.separator))
                                .frame(height: 0.5)
                                .padding(.leading, separatorInset)
                        }
                        row
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.lg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The leading part of a row: a coloured icon tile (or any view), a title and
/// an optional line under it.
struct DSRowLabel<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension DSRowLabel where Leading == SettingsIcon {
    init(_ title: String, subtitle: String? = nil, icon: String, color: Color) {
        self.init(title: title, subtitle: subtitle) { SettingsIcon(systemName: icon, color: color) }
    }
}

extension DSRowLabel where Leading == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A tappable row that goes somewhere or does something, with a chevron.
struct DSNavigationRow<Leading: View>: View {
    let label: DSRowLabel<Leading>
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                label
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .dsRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A row with a switch.
struct DSToggleRow<Leading: View>: View {
    let label: DSRowLabel<Leading>
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .tint(.accentColor)
            .dsRowPadding()
    }
}

/// One choice among several: a checkmark on the chosen one.
struct DSChoiceRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                DSRowLabel(title, subtitle: subtitle)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .dsRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// The standard padding inside a group row.
    func dsRowPadding() -> some View {
        padding(.horizontal, DS.Spacing.lg).padding(.vertical, 11)
    }
}

// MARK: - Buttons

/// The page's main action: a full-width pink button.
struct DSPrimaryButtonStyle: ButtonStyle {
    var working = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            configuration.label.opacity(working ? 0 : 1)
            if working { ProgressView().tint(.white) }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Color.accentColor.opacity(isEnabled ? 1 : 0.4),
                    in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
        .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A second action under the main one: the card fill with pink text.
struct DSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(.secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A small action inside a row ("Message", "Add").
struct DSPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.14), in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
    static func dsPrimary(working: Bool) -> DSPrimaryButtonStyle { DSPrimaryButtonStyle(working: working) }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
}

extension ButtonStyle where Self == DSPillButtonStyle {
    static var dsPill: DSPillButtonStyle { DSPillButtonStyle() }
}

// MARK: - Steps

/// Where a step-by-step flow is: a short bar for each step.
struct DSStepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color(.tertiaryLabel))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .animation(DS.Motion.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
