//
//  SendTokens.swift
//  Relay
//
//  Anonymous send tokens (server internal/sendtoken, README "Send tokens").
//  The relay limits sealed sends, sealed key fetches and call rings by a token
//  instead of by our address. The app collects a batch while signed in,
//  blinded so the relay can't recognise them when they come back, and spends
//  one per anonymous request. Same construction as the Supporter credentials
//  (SupporterCredential.swift) under the send-token domain tags.
//

import Foundation
import OSLog
import RelayKit

actor SendTokenPool {
    /// The relay's send-token key (`relayd -send-token-public-key`). Built in
    /// rather than fetched, so the relay can't give each account its own key
    /// and recognise whose tokens it gets back.
    nonisolated static let publicKey = Data(base64Encoded: "Xn2m+m1iwE55cxI986TdcadOxPbeuVjk4c8q2v9u+l4=")!

    private static let log = Logger(subsystem: "app.relaymsg", category: "send-tokens")
    private static let batch = 100
    private static let lowWater = 40

    private var api: RelayAPIClient?
    private var tokens: [(day: Int64, value: String)] = []
    private var refilling: Task<Void, Never>?
    private var retryAfter: Date?
    /// The relay's day minus ours, from its last answer (a wrong clock).
    private var dayOffset: Int64 = 0

    func configure(_ api: RelayAPIClient) {
        self.api = api
        _ = refill()
    }

    private var localDay: Int64 { Int64(Date().timeIntervalSince1970) / 86400 }

    /// A token for one anonymous request, or nil if none could be had (the
    /// request then goes without, which the relay accepts until it requires
    /// them).
    func take() async -> String? {
        let today = localDay + dayOffset
        tokens.removeAll { $0.day < today - 1 }
        if tokens.isEmpty {
            await refill().value
        } else if tokens.count < Self.lowWater {
            _ = refill()
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.removeFirst().value
    }

    private func refill() -> Task<Void, Never> {
        if let refilling { return refilling }
        let task = Task {
            await fetch()
            refilling = nil
        }
        refilling = task
        return task
    }

    private func fetch() async {
        guard let api, retryAfter.map({ $0 < Date() }) ?? true else { return }
        var day = localDay + dayOffset
        for _ in 0..<2 {
            let pending = (0..<Self.batch).compactMap { _ in
                SupporterCredential.blind(period: String(day), suite: .sendToken)
            }
            guard pending.count == Self.batch,
                  let answer = try? await api.sendTokens(day: day, blinded: pending.map(\.blinded))
            else {
                Self.log.info("send tokens: couldn't fetch a batch")
                retryAfter = Date().addingTimeInterval(60)
                return
            }
            if answer.day != day {
                dayOffset = answer.day - localDay
                day = answer.day
                continue
            }
            var batch: [(day: Int64, value: String)] = []
            for (p, t) in zip(pending, answer.tokens) {
                // A proof that doesn't check means a key other than the
                // built-in one: none of the batch is used.
                guard let token = SupporterCredential.finish(p, evaluated: t.evaluated, proof: t.proof,
                                                             publicKey: Self.publicKey, suite: .sendToken)
                else {
                    Self.log.error("send tokens: a proof didn't verify against the built-in key")
                    retryAfter = Date().addingTimeInterval(3600)
                    return
                }
                batch.append((day, String(day) + "." + Self.base64URL(token.nonce + token.point)))
            }
            tokens += batch
            Self.log.info("send tokens: got \(batch.count, privacy: .public)")
            return
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
