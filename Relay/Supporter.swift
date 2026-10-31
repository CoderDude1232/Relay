//
//  Supporter.swift
//  Relay
//
//  Relay Supporter: an optional monthly subscription that pays for the
//  servers. Every feature stays free; supporters get cosmetic extras. The
//  entitlement is checked on this device with StoreKit and never sent to the
//  relay, so paying isn't linked to the account.
//

import StoreKit
import SwiftUI

@Observable
final class Supporter {
    static let shared = Supporter()

    /// One subscription group, three levels (App Store Connect → Subscriptions
    /// → "Relay Supporter"). Same perks at every level.
    static let productIds = [
        "app.relaymsg.supporter.monthly1",
        "app.relaymsg.supporter.monthly2",
        "app.relaymsg.supporter.monthly3",
    ]

    private static let cacheKey = "supporter.active"

    /// Cached so the perks show at launch before StoreKit answers.
    private(set) var isActive = UserDefaults.standard.bool(forKey: Supporter.cacheKey) {
        didSet { UserDefaults.standard.set(isActive, forKey: Self.cacheKey) }
    }

    /// Whether the App Store has the products (hidden until they're live in
    /// App Store Connect, and in regions where they aren't sold).
    private(set) var isAvailable = false

    /// Show "Support Relay" and its perks.
    var isOffered: Bool { isAvailable || isActive }

    @ObservationIgnored private var updates: Task<Void, Never>?

    /// Call once at launch: finishes renewals and refunds that arrived while
    /// the app was closed and keeps `isActive` current.
    func start() {
        guard updates == nil else { return }
        updates = Task {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await refresh()
            }
        }
        Task {
            await refresh()
            isAvailable = (try? await Product.products(for: Self.productIds))?.isEmpty == false
        }
    }

    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIds.contains(transaction.productID),
                  transaction.revocationDate == nil
            else { continue }
            active = true
        }
        isActive = active
    }
}

// MARK: - Screen

/// Settings → Support Relay.
struct SupporterView: View {
    @Environment(\.dismiss) private var dismiss
    private var supporter = Supporter.shared

    var body: some View {
        SubscriptionStoreView(productIDs: Supporter.productIds) {
            header
        }
        .subscriptionStoreControlStyle(.picker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.hidden, for: .cancellation)
        .subscriptionStorePolicyDestination(url: LegalLinks.terms, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: LegalLinks.privacy, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success) = result {
                await supporter.refresh()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
            .padding(16)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 44))
                .foregroundStyle(.pink.gradient)
                .padding(.top, 36)
            Text(supporter.isActive ? "Thanks for supporting Relay" : "Support Relay")
                .font(.system(.title, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text("No ads and no selling data. Relay is paid for by the people who use it. Every feature stays free.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                perk("paintpalette.fill", "Supporter wallpapers")
                perk("heart.circle.fill", "A supporter heart on your profile")
                perk("lock.fill", "Private: only your device knows you subscribe")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private func perk(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: icon).foregroundStyle(.pink)
        }
    }
}
