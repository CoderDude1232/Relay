//
//  PushKitDelegate.swift
//  Relay
//
//  Registers for PushKit VoIP pushes and reports incoming calls to CallKit.
//
//  iOS stops delivering VoIP pushes to apps that break these rules:
//  1. reportNewIncomingCall must be called before didReceiveIncomingPushWith returns.
//  2. The PushKit completion must be called from reportNewIncomingCall's callback,
//     after CallKit has acknowledged the call.
//  The registry runs on the main queue, so MainActor.assumeIsolated can call
//  main-actor code synchronously, which keeps rule 1 intact.
//

import CallKit
import Foundation
import OSLog
import PushKit
import RelayKit

@MainActor
final class PushKitDelegate: NSObject, PKPushRegistryDelegate {
    private let registry = PKPushRegistry(queue: .main)
    private var callManager: CallManager?
    private var apiClient: RelayAPIClient?
    private var pendingCallId: String?
    // Cached so we can upload the token even if apiClient arrives after PushKit fires.
    private var cachedVoIPToken: String?
    private let log = Logger(subsystem: "app.relaymsg", category: "PushKit")

    override init() {
        super.init()
        registry.delegate = self
    }

    func start(callManager: CallManager) {
        self.callManager = callManager
        registry.desiredPushTypes = [.voIP]
        if let callId = pendingCallId {
            pendingCallId = nil
            callManager.reportIncomingPushCall(callId: callId, pushCompletion: {})
        }
    }

    func wire(apiClient: RelayAPIClient) {
        self.apiClient = apiClient
        // Upload any token that arrived before the service was ready.
        if let token = cachedVoIPToken {
            Task {
                do {
                    try await apiClient.setVoIPToken(token)
                    log.info("cached voip token uploaded")
                } catch {
                    log.warning("cached voip token upload failed: \(PrivacyRedactor.error(error))")
                }
            }
        }
    }

    // MARK: - PKPushRegistryDelegate

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            cachedVoIPToken = token
            log.info("voip token updated")
            if let client = apiClient {
                do {
                    try await client.setVoIPToken(token)
                    log.info("voip token uploaded")
                } catch {
                    log.warning("voip token upload failed: \(PrivacyRedactor.error(error))")
                }
            }
            // Otherwise wire() uploads it once the service is ready.
        }
    }

    /// Called on iOS 17 and earlier.
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        handleVoIPPayload(payload.dictionaryPayload, completion: completion)
    }

    /// Takes precedence over the generic delegate method on iOS 26.4+.
    @available(iOS 26.4, *)
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingVoIPPushWith payload: PKPushPayload,
        metadata: PKVoIPPushMetadata,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        handleVoIPPayload(payload.dictionaryPayload, completion: completion)
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

    // MARK: - Shared handler

    /// The VoIP push carries only an opaque `call_id`; anything else in the
    /// payload is untrusted and ignored. CallManager reports a generic "Relay"
    /// call and learns the caller from the encrypted OFFER with the same id,
    /// or ends the call if none arrives.
    nonisolated private func handleVoIPPayload(_ dict: [AnyHashable: Any], completion: @escaping () -> Void) {
        let rawCallId = (dict["call_id"] as? String) ?? ""
        // A malformed id must still be reported to CallKit, but is ended at once.
        let callId = Self.isPlausibleCallId(rawCallId) ? rawCallId : ""

        // assumeIsolated runs synchronously (no dispatch), so the call is
        // reported before this function returns.
        MainActor.assumeIsolated {
            if let cm = callManager {
                // CallManager calls completion from reportNewIncomingCall's callback.
                cm.reportIncomingPushCall(callId: callId, pushCompletion: completion)
            } else {
                // AppDelegate.start() hasn't run yet; it flushes the stored id.
                pendingCallId = callId
                completion()
            }
        }
    }

    nonisolated private static func isPlausibleCallId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }
}
