//
//  ScamCheck.swift
//  Relay
//
//  On-device scam warnings for incoming messages. Apple's on-device language
//  model looks at a message that has the usual signs (a link, money, codes,
//  urgency) and, if it matches a common scam pattern, the chat shows a
//  warning under it. Nothing is sent anywhere, and nothing is reported unless
//  the user taps Report themselves.
//
//  Only the kind of scam is stored (in the encrypted database), never text
//  from the model, so a verdict can't carry message content past a
//  disappearing-message timer.
//

import Foundation
import FoundationModels
import SecureStorage

enum ScamKind: String, Codable, CaseIterable {
    case suspiciousLink, codeOrPasswordRequest, moneyRequest, cryptoOrInvestment
    case impersonation, prizeOrDelivery, jobOffer

    var title: String {
        switch self {
        case .suspiciousLink: "This link may be a scam"
        case .codeOrPasswordRequest: "Asks for a code or password"
        case .moneyRequest: "Asks for money"
        case .cryptoOrInvestment: "Possible investment or crypto scam"
        case .impersonation: "May be pretending to be someone else"
        case .prizeOrDelivery: "Possible prize or delivery scam"
        case .jobOffer: "Possible job or task scam"
        }
    }

    var advice: String {
        switch self {
        case .suspiciousLink:
            "Don't sign in or pay through links you weren't expecting."
        case .codeOrPasswordRequest:
            "Never share sign-in codes or passwords, even with someone you know."
        case .moneyRequest:
            "Check with the person another way before sending money or gift cards."
        case .cryptoOrInvestment:
            "Promised returns and crypto tips from strangers are a common scam."
        case .impersonation:
            "Banks, companies and support teams don't contact you on Relay."
        case .prizeOrDelivery:
            "Prizes and parcel fees you weren't expecting are a common scam."
        case .jobOffer:
            "Jobs that pay for simple tasks or ask you to pay first are a common scam."
        }
    }
}

enum ScamCheck {
    static let enabledKey = "relay.scamWarnings"

    /// On by default: it runs on the device and only warns the user.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var isAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    /// Cheap filter before the model: scams nearly always carry a link, a
    /// mention of money, codes or accounts, or pressure to act.
    static func worthChecking(_ body: String) -> Bool {
        let text = body.lowercased()
        guard text.count >= 12 else { return false }
        if body.firstURL != nil || text.contains("www.") || text.contains(".com") { return true }
        let signals = [
            "$", "€", "£", "usd", "money", "pay", "payment", "transfer", "bank", "account",
            "gift card", "giftcard", "itunes", "steam card", "crypto", "bitcoin", "btc", "usdt", "wallet",
            "invest", "profit", "return", "trading", "code", "otp", "password", "verify", "verification",
            "login", "sign in", "urgent", "immediately", "suspended", "locked", "won", "winner", "prize",
            "claim", "reward", "parcel", "package", "delivery", "customs", "fee", "job", "hiring",
            "salary", "commission", "task", "loan", "refund", "irs", "tax", "support team", "security team",
        ]
        return signals.contains { text.contains($0) }
    }
}

@available(iOS 26.0, *)
@Generable
enum ScamVerdict {
    case notAScam
    case suspiciousLink
    case codeOrPasswordRequest
    case moneyRequest
    case cryptoOrInvestment
    case impersonation
    case prizeOrDelivery
    case jobOffer

    var kind: ScamKind? {
        switch self {
        case .notAScam: nil
        case .suspiciousLink: .suspiciousLink
        case .codeOrPasswordRequest: .codeOrPasswordRequest
        case .moneyRequest: .moneyRequest
        case .cryptoOrInvestment: .cryptoOrInvestment
        case .impersonation: .impersonation
        case .prizeOrDelivery: .prizeOrDelivery
        case .jobOffer: .jobOffer
        }
    }
}

@available(iOS 26.0, *)
@Generable
struct ScamAssessment {
    @Guide(description: "notAScam unless the message clearly follows a common scam pattern")
    var verdict: ScamVerdict
}

/// One message at a time, so a chat full of links doesn't start a dozen model
/// sessions at once.
@available(iOS 26.0, *)
actor ScamChecker {
    static let shared = ScamChecker()

    private static let instructions = """
        You check one chat message for signs of a scam, to warn the person who received it. \
        Most messages are ordinary: friends sharing links, splitting bills, talking about work or money. \
        Answer notAScam unless the message clearly matches a common scam: a link asking someone to sign in, \
        pay or "verify" an account; a request for a one-time code or password; an urgent request for money \
        or gift cards; a crypto or investment opportunity; someone claiming to be a bank, company, \
        government or support team; an unexpected prize, refund or parcel fee; or a job paying for simple tasks.
        """

    /// The scam kind for this message, or nil when it looks fine or the model
    /// can't say (unavailable, refused, or failed).
    func assess(_ body: String, fromStranger: Bool) async -> ScamKind? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: Self.instructions)
        let sender = fromStranger
            ? "The sender is someone the recipient hasn't chatted with before."
            : "The sender is an existing contact (whose account could have been taken over)."
        let prompt = "\(sender)\n\nMessage:\n\"\"\"\n\(body.prefix(2000))\n\"\"\""
        do {
            let response = try await session.respond(
                to: prompt, generating: ScamAssessment.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content.verdict.kind
        } catch {
            return nil
        }
    }
}

// MARK: - Results, kept in the encrypted database

extension MessagingService {
    private static func scamKey(_ messageId: String) -> String { "scam:" + messageId }
    private static let scamClean = "clean"
    private static let scamDismissed = "dismissed"

    private func storedScamResult(_ messageId: String) -> String? {
        let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(Self.scamKey(messageId))]
        ).first?.first?.data) ?? nil
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    private func storeScamResult(_ value: String, for messageId: String) {
        try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                  [.text(Self.scamKey(messageId)), .blob(Data(value.utf8))])
    }

    /// The warning to show under an incoming message, if any.
    func scamWarning(for messageId: String) -> ScamKind? {
        storedScamResult(messageId).flatMap(ScamKind.init(rawValue:))
    }

    /// "Not a scam": hides the warning for good.
    func dismissScamWarning(for messageId: String) {
        storeScamResult(Self.scamDismissed, for: messageId)
    }

    /// Checks an incoming message once, on the device, and returns a warning
    /// to show. Recent messages only, so opening an old chat doesn't run the
    /// model over its history.
    func checkForScam(_ message: StoredMessage, in conversationId: String) async -> ScamKind? {
        guard #available(iOS 26.0, *) else { return nil }
        if let stored = storedScamResult(message.id) { return ScamKind(rawValue: stored) }
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - message.timestamp
        guard ScamCheck.isEnabled, ScamCheck.isAvailable,
              !message.isOutgoing, !message.isDeleted,
              message.senderAccount != Self.systemSender,
              ageMs < 7 * 86_400_000,
              ScamCheck.worthChecking(message.body)
        else { return nil }
        let conversation = conversations.first { $0.id == conversationId }
        // The official Relay chat and Note to Self are local.
        if let peer = conversation?.peerAccount, peer == Self.relayOfficialAccount || peer == noteToSelfAccount {
            return nil
        }
        let fromStranger = conversation?.isRequest ?? true
        let kind = await ScamChecker.shared.assess(message.body, fromStranger: fromStranger)
        storeScamResult(kind?.rawValue ?? Self.scamClean, for: message.id)
        return kind
    }
}

// MARK: - Warning under a message

import SwiftUI

struct ScamWarningView: View {
    let message: StoredMessage
    let conversationId: String
    let service: MessagingService
    /// Who to report: the 1:1 peer, or the sender in a group.
    let senderAccount: String?
    let senderName: String

    @State private var kind: ScamKind?
    @State private var reporting = false

    var body: some View {
        Group {
            if let kind {
                VStack(alignment: .leading, spacing: 6) {
                    Label(kind.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(kind.advice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        if senderAccount != nil {
                            Button("Report") { reporting = true }
                        }
                        Button("Not a Scam") {
                            service.dismissScamWarning(for: message.id)
                            withAnimation { self.kind = nil }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    Text("Checked on your iPhone. Nothing was sent anywhere.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: 280, alignment: .leading)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .sheet(isPresented: $reporting) {
                    if let senderAccount {
                        ReportContactSheet(service: service, account: senderAccount, displayName: senderName)
                    }
                }
            }
        }
        .task(id: message.id) {
            kind = service.scamWarning(for: message.id)
            if kind == nil, let found = await service.checkForScam(message, in: conversationId) {
                withAnimation { kind = found }
            }
        }
    }
}
