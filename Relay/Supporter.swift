//
//  Supporter.swift
//  Relay
//
//  Relay Supporter: an optional monthly subscription that pays for the
//  servers. Every feature stays free; supporters get bigger files, original
//  quality media, attachments in backups, more linked devices, app icons and
//  wallpapers.
//
//  The relay grants the account perks without learning who paid: the
//  purchase is traded for anonymous credentials on an unauthenticated
//  request, and one is redeemed per period on the account after a random
//  delay (see SupporterCredential.swift and the server README).
//

import RelayKit
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

    private static let storeKey = "supporter.active"
    private static let untilKey = "supporter.until"
    private static let tokensKey = "supporter.tokens"
    private static let issuedKey = "supporter.issuedTransactions"
    private static let periodKeysKey = "supporter.periodKeys"

    /// This Apple Account pays (cached so perks show before StoreKit answers).
    private(set) var storeActive = UserDefaults.standard.bool(forKey: Supporter.storeKey) {
        didSet { UserDefaults.standard.set(storeActive, forKey: Self.storeKey) }
    }

    /// Until when the relay gives this account supporter perks (unix ms).
    private(set) var accountUntil = Int64(UserDefaults.standard.integer(forKey: Supporter.untilKey)) {
        didSet { UserDefaults.standard.set(Int(accountUntil), forKey: Self.untilKey) }
    }

    /// The account has the relay's perks (bigger files, more devices…).
    var hasAccountPerks: Bool { accountUntil > Int64(Date().timeIntervalSince1970 * 1000) }

    /// Show supporter perks: this Apple Account pays or the account has them
    /// (a linked device on someone else's Apple Account).
    var isActive: Bool { storeActive || hasAccountPerks }

    /// Whether the App Store has the products (hidden until they're live in
    /// App Store Connect, and in regions where they aren't sold).
    private(set) var isAvailable = false

    /// Show "Support Relay" and its perks.
    var isOffered: Bool { isAvailable || isActive }

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private weak var service: MessagingService?
    @ObservationIgnored private var syncing = false

    /// Call once at launch: finishes renewals and refunds that arrived while
    /// the app was closed and keeps the status current.
    func start() {
        guard updates == nil else { return }
        updates = Task {
            for await result in StoreKit.Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await sync()
            }
        }
        Task {
            await refreshStore()
            isAvailable = (try? await Product.products(for: Self.productIds))?.isEmpty == false
        }
    }

    /// The signed-in account's service, once it's running.
    func attach(_ service: MessagingService) {
        self.service = service
        Task { await sync() }
    }

    /// Sign-out: the next account starts without perks or credentials.
    func resetAccount() {
        service = nil
        accountUntil = 0
    }

    private func refreshStore() async {
        var active = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIds.contains(transaction.productID),
                  transaction.revocationDate == nil
            else { continue }
            active = true
        }
        storeActive = active
    }

    // MARK: Credentials

    /// Brings everything up to date: StoreKit status, the account's perks,
    /// credentials for current purchases, and redeeming this period's.
    func sync() async {
        await refreshStore()
        guard let service, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let api = service.apiClient
        guard let status = try? await api.supporterStatus(), status.available else { return }
        accountUntil = status.supporterUntil
        var issuedNow = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIds.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  let expires = transaction.expirationDate, expires > Date()
            else { continue }
            if await issue(for: transaction, jws: result.jwsRepresentation, api: api) { issuedNow = true }
        }
        await redeemDue(api: api, delay: issuedNow)
    }

    /// Gets credentials for the periods a purchase covers that this account
    /// doesn't have yet. Returns whether it got any.
    private func issue(for transaction: StoreKit.Transaction, jws: String, api: RelayAPIClient) async -> Bool {
        let txId = String(transaction.id)
        var issued = Set(UserDefaults.standard.stringArray(forKey: Self.issuedKey) ?? [])
        guard !issued.contains(txId), transaction.environment != .xcode,
              let expires = transaction.expirationDate else { return false }
        let held = Set(tokens.map(\.period))
        let untilDate = Date(timeIntervalSince1970: TimeInterval(accountUntil) / 1000)
        let periods = SupporterCredential.periods(
            from: Date(), until: expires, sandbox: transaction.environment == .sandbox
        ).filter { p in !held.contains(p) && (SupporterCredential.end(of: p).map { $0 > untilDate } ?? false) }
        guard !periods.isEmpty, let keys = await periodKeys(api: api) else { return false }

        let pending = periods.compactMap { SupporterCredential.blind(period: $0) }
        guard pending.count == periods.count else { return false }
        do {
            let issuedCreds = try await api.issueSupporterCredentials(
                transaction: jws,
                requests: pending.map { .init(period: $0.period, blinded: $0.blinded) })
            var got: [SupporterCredential.Token] = []
            for cred in issuedCreds {
                guard let p = pending.first(where: { $0.period == cred.period }), let key = keys[cred.period],
                      let token = SupporterCredential.finish(p, evaluated: cred.evaluated, proof: cred.proof, publicKey: key)
                else { continue }
                got.append(token)
            }
            tokens += got
            issued.insert(txId)
            UserDefaults.standard.set(Array(issued), forKey: Self.issuedKey)
            return !got.isEmpty
        } catch RelayAPIError.http(let status, _) where status == 409 || status == 403 {
            // Used up (a reinstall already reissued) or not a usable purchase.
            issued.insert(txId)
            UserDefaults.standard.set(Array(issued), forKey: Self.issuedKey)
            return false
        } catch {
            return false
        }
    }

    /// Each period's public key. A key never changes once seen, so a relay
    /// that hands this device its own key (to recognise it later) is caught.
    private func periodKeys(api: RelayAPIClient) async -> [String: Data]? {
        guard let fetched = try? await api.supporterKeys() else { return nil }
        var known = (UserDefaults.standard.dictionary(forKey: Self.periodKeysKey) as? [String: Data]) ?? [:]
        for (period, key) in fetched {
            if let seen = known[period], seen != key { return nil }
            known[period] = key
        }
        let now = Date()
        known = known.filter { SupporterCredential.end(of: $0.key).map { $0 > now } ?? false }
        UserDefaults.standard.set(known, forKey: Self.periodKeysKey)
        return known
    }

    private var tokens: [SupporterCredential.Token] {
        get {
            UserDefaults.standard.data(forKey: Self.tokensKey)
                .flatMap { try? JSONDecoder().decode([SupporterCredential.Token].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.tokensKey) }
    }

    /// Redeems the credential for the current period, if the account doesn't
    /// already have it; drops ones whose period is over. After a fresh issue
    /// it waits a random while, so the relay can't pair the two requests by
    /// timing.
    private func redeemDue(api: RelayAPIClient, delay: Bool) async {
        let now = Date()
        var remaining = tokens.filter { SupporterCredential.end(of: $0.period).map { $0 > now } ?? false }
        tokens = remaining
        let untilDate = Date(timeIntervalSince1970: TimeInterval(accountUntil) / 1000)
        for token in remaining {
            guard let end = SupporterCredential.end(of: token.period),
                  token.period == SupporterCredential.period(at: now, sandbox: token.period.hasPrefix("h"))
            else { continue }
            if end <= untilDate {
                continue  // already covered
            }
            if delay { try? await Task.sleep(for: .seconds(Double.random(in: 15...120))) }
            do {
                accountUntil = try await api.redeemSupporterCredential(
                    period: token.period, nonce: token.nonce, credential: token.point)
                remaining.removeAll { $0 == token }
            } catch RelayAPIError.http(let status, _) where status == 409 || status == 403 {
                remaining.removeAll { $0 == token }
            } catch {}
        }
        tokens = remaining
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
                await supporter.sync()
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
                perk("doc.fill", "Send files up to 95 MB, not 25 MB")
                perk("photo.fill", "Photos sent at full resolution")
                perk("externaldrive.fill.badge.icloud", "Photos and files in your encrypted backup")
                perk("laptopcomputer.and.iphone", "Link up to 10 devices, not 5")
                perk("app.badge.fill", "App icons, wallpapers and a supporter heart")
                perk("lock.fill", "Private: Relay can't link your payment to your account")
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
