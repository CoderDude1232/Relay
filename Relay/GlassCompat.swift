//
//  GlassCompat.swift
//  Relay
//
//  Backward-compatible shims for Liquid Glass APIs introduced in iOS 26.
//  On iOS 18–25 all glass surfaces degrade to ultraThinMaterial.
//

import SwiftUI

// MARK: - Glass modifiers

extension View {
    /// Applies glassEffect(in:) on iOS 26+; falls back to ultraThinMaterial.
    @ViewBuilder
    func glassCompat(in shape: some InsettableShape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Applies glassEffect() on iOS 26+; falls back to ultraThinMaterial background.
    @ViewBuilder
    func glassCompat() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect()
        } else {
            background(.ultraThinMaterial)
        }
    }
}

// MARK: - GlassEffectContainer replacement

/// Wraps content in GlassEffectContainer on iOS 26+; on older OS it is a plain passthrough.
struct GlassContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

// MARK: - glassProminent button style replacement

extension View {
    /// Applies .glassProminent on iOS 26+; falls back to .borderedProminent.
    @ViewBuilder
    func glassProminentCompat() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Applies .glass on iOS 26+; falls back to .bordered.
    @ViewBuilder
    func glassStyleCompat() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
