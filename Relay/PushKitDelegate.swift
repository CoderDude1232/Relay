//
//  PushKitDelegate.swift
//  Relay
//
//  Registers for PushKit VoIP pushes and reports incoming calls to CallKit.
//
//  Critical rules (iOS 13+):
//  1. provider.reportNewIncomingCall must be called before didReceiveIncomingPushWith returns.
//  2. The PushKit completion() must be called INSIDE reportNewIncomingCall's callback,
//     not before it — Apple's own sample code shows this pattern. Calling completion()
//     before CallKit has acknowledged the call causes iOS to consider the push unhandled,
//     and eventually blacklists the app from receiving future VoIP pushes.
//  3. PKPushRegistry(queue: .main) fires on the main queue = MainActor's executor, so
//     MainActor.assumeIsolated{} lets us call @MainActor code synchronously with no
//     Task dispatch, satisfying rule 1.
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
            // else: wire() will upload it once the service is ready
        }
    }

    /// Legacy method — still called on iOS 17 and earlier.
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

    /// The VoIP push carries ONLY an opaque `call_id`. Any caller name, account
    /// or call kind in the payload is ignored: the push travels via Apple and
    /// the relay, so nothing in it is trusted. CallManager reports a generic
    /// "Relay" call immediately and learns the real caller from the end-to-end
    /// encrypted OFFER with the same call id (or ends the call if none arrives).
    nonisolated private func handleVoIPPayload(_ dict: [AnyHashable: Any], completion: @escaping () -> Void) {
        let rawCallId = (dict["call_id"] as? String) ?? ""
        // Accept only a sane, bounded id; anything else still has to be reported
        // to CallKit (PushKit contract) but is ended immediately.
        let callId = Self.isPlausibleCallId(rawCallId) ? rawCallId : ""

        // Running on the main queue. MainActor.assumeIsolated does NOT dispatch;
        // it asserts we are already on the main actor and runs synchronously,
        // satisfying Apple's requirement that reportNewIncomingCall is called
        // before this function returns.
        MainActor.assumeIsolated {
            if let cm = callManager {
                // Pass completion through — CallManager calls it inside
                // reportNewIncomingCall's callback (the correct place per Apple docs).
                cm.reportIncomingPushCall(callId: callId, pushCompletion: completion)
            } else {
                // App just launched; AppDelegate.start() hasn't run yet.
                // Store the call id — start() will flush it.
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
