//
//  EmptyStates.swift
//  Relay
//
//  The look for empty lists and the placeholder rows shown while chats load.
//

import SwiftUI

/// Icon in a soft tinted circle, a title, a line of help and an optional
/// button.
struct RelayEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.opacity(0.12), in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }
}

/// A grey stand-in for a chat row, gently pulsing.
struct ChatRowSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().frame(width: 130, height: 12)
                Capsule().frame(maxWidth: 220).frame(height: 10)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.secondary.opacity(dim ? 0.12 : 0.22))
        .padding(.vertical, 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityHidden(true)
    }
}
