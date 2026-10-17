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

    /// Whether Apple's on-device model can help. The rules below work without it.
    static var isModelAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    // MARK: Rules

    /// Brands scammers pretend to be, as they appear in messages and domains.
    private static let brands = [
        "apple", "icloud", "appleid", "apple id", "paypal", "amazon", "netflix", "microsoft", "outlook",
        "google", "gmail", "instagram", "facebook", "meta", "whatsapp", "telegram", "relay", "bank",
        "chase", "wells fargo", "citi", "hsbc", "barclays", "commbank", "westpac", "anz", "nab",
        "irs", "hmrc", "ato", "mygov", "medicare", "usps", "ups", "fedex", "dhl", "royal mail",
        "auspost", "australia post", "evri", "coinbase", "binance", "metamask", "steam", "venmo",
        "cash app", "zelle", "revolut", "wise",
    ]
    /// The brands' own domains, so their real links don't trip the look-alike rule.
    private static let officialDomains = [
        "apple.com", "icloud.com", "paypal.com", "amazon.com", "amazon.co.uk", "amazon.com.au",
        "netflix.com", "microsoft.com", "live.com", "outlook.com", "google.com", "gmail.com",
        "instagram.com", "facebook.com", "whatsapp.com", "telegram.org", "relaymsg.app", "usps.com",
        "ups.com", "fedex.com", "dhl.com", "royalmail.com", "auspost.com.au", "coinbase.com",
        "binance.com", "steampowered.com", "venmo.com", "cash.app", "revolut.com", "wise.com",
        "irs.gov", "gov.uk", "ato.gov.au", "my.gov.au", "youtube.com", "youtu.be",
    ]
    private static let shorteners = [
        "bit.ly", "tinyurl.com", "t.co", "goo.gl", "is.gd", "cutt.ly", "rb.gy", "ow.ly", "shorturl.at", "tiny.cc",
    ]
    private static let accountPressure = [
        "verify", "verification", "locked", "suspended", "disabled", "unusual activity", "unusual sign",
        "confirm your", "update your", "reactivate", "restore access", "will be closed", "will be deleted",
        "unauthorized", "unauthorised", "security alert", "sign in to", "log in to", "login to",
    ]

    private static func hosts(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { $0.url?.host?.lowercased() }
    }

    private static func isOfficial(_ host: String) -> Bool {
        officialDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Patterns clear enough to warn about without the model: a look-alike
    /// or shortened link, a link with account pressure, a request for a code,
    /// gift cards, a parcel fee, a prize to claim.
    static func ruleVerdict(_ body: String) -> ScamKind? {
        let text = body.lowercased()
        let linkHosts = hosts(in: body)
        let hasLink = !linkHosts.isEmpty
        let mentionsBrand = brands.contains { text.contains($0) }
        let pressure = accountPressure.contains { text.contains($0) }
        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        // Specific asks first, so the warning names what's being asked for.
        if any(["gift card", "giftcard", "itunes card", "steam card", "google play card"])
            && any(["buy", "send", "purchase", "get me", "scratch", "pictures of", "photo of", "photos of"]) {
            return .moneyRequest
        }
        // Someone asking us for a code that was sent to us.
        if any(["sent you a code", "sent you a 6", "sent you a six", "code i sent", "code that was sent", "code you received",
                "code you got", "send me the code", "send me that code", "send it back", "share the code",
                "give me the code", "tell me the code", "read me the code", "what's the code you", "verification code",
                "one-time code", "one time code", "otp"])
            && any(["send", "share", "give", "tell me", "read me", "forward", "what's", "whats"])
            && !any(["didn't get", "didnt get", "isn't arriving", "not arriving", "never got"]) {
            return .codeOrPasswordRequest
        }
        if any(["your password", "your passcode", "your login"]) && any(["send me", "tell me", "share", "give me", "what's", "whats"]) {
            return .codeOrPasswordRequest
        }
        if any(["parcel", "package", "delivery", "shipment", "customs"])
            && any(["fee", "pay", "held", "redeliver", "redelivery", "failed"]) && hasLink {
            return .prizeOrDelivery
        }
        if any(["you won", "you've won", "you have won", "winner", "you've been selected", "selected to receive"])
            && any(["claim", "prize", "reward", "gift card", "$", "£", "€"]) {
            return .prizeOrDelivery
        }
        if any(["usdt", "bitcoin", "btc", "crypto", "forex", "trading platform"])
            && any(["profit", "return", "invest", "earn", "guaranteed", "% weekly", "% daily", "double"]) {
            return .cryptoOrInvestment
        }
        if any(["new number", "lost my phone", "phone broke", "broke my phone"])
            && any(["pay", "money", "transfer", "bill", "send", "lend"]) {
            return .impersonation
        }
        for host in linkHosts where !isOfficial(host) {
            let compact = host.replacingOccurrences(of: "-", with: "")
            // A brand in someone else's domain: apple-id-check.co, paypal.secure-login.net.
            if brands.contains(where: { $0.count >= 4 && compact.contains($0.replacingOccurrences(of: " ", with: "")) }) {
                return mentionsBrand && pressure ? .impersonation : .suspiciousLink
            }
            if shorteners.contains(host) && (pressure || mentionsBrand) { return .suspiciousLink }
            if host.hasPrefix("xn--") || host.contains(".xn--") { return .suspiciousLink }
            if host.allSatisfy({ $0.isNumber || $0 == "." }) { return .suspiciousLink }
        }
        if hasLink && pressure && linkHosts.contains(where: { !isOfficial($0) }) {
            return mentionsBrand ? .impersonation : .suspiciousLink
        }
        return nil
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

    enum Outcome { case scam(ScamKind), clean, failed }

    /// The model's verdict, or `.failed` when it couldn't say (unavailable,
    /// refused by its safety filters, or an error); that's not "clean".
    func assess(_ body: String, fromStranger: Bool) async -> Outcome {
        guard SystemLanguageModel.default.availability == .available else { return .failed }
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
            return response.content.verdict.kind.map(Outcome.scam) ?? .clean
        } catch {
            return .failed
        }
    }
}

// MARK: - Results, kept in the encrypted database

extension MessagingService {
    // v2: earlier builds stored "clean" when the model failed.
    private static func scamKey(_ messageId: String) -> String { "scam2:" + messageId }
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
        if let stored = storedScamResult(message.id) { return ScamKind(rawValue: stored) }
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - message.timestamp
        guard ScamCheck.isEnabled,
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
        if let kind = ScamCheck.ruleVerdict(message.body) {
            storeScamResult(kind.rawValue, for: message.id)
            return kind
        }
        guard #available(iOS 26.0, *), ScamCheck.isModelAvailable else { return nil }
        let fromStranger = conversation?.isRequest ?? true
        switch await ScamChecker.shared.assess(message.body, fromStranger: fromStranger) {
        case .scam(let kind):
            storeScamResult(kind.rawValue, for: message.id)
            return kind
        case .clean:
            storeScamResult(Self.scamClean, for: message.id)
            return nil
        case .failed:
            return nil // asked again next time the message is shown
        }
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
