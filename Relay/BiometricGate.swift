//
//  BiometricGate.swift
//  Relay
//

import Foundation
import LocalAuthentication

enum BiometricGate {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        // `.deviceOwnerAuthentication` falls back to the device passcode, so a
        // phone without Face ID enrolled — or locked out after failed attempts —
        // can still get in. Biometrics-only would lock the user out of their
        // own media and chats with no way back.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set at all: there is nothing to authenticate against,
            // so the lock can't protect anything — let the user through.
            return (error as? LAError)?.code == .passcodeNotSet
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
