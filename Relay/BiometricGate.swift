//
//  BiometricGate.swift
//  Relay
//

import Foundation
import LocalAuthentication

enum BiometricGate {
    /// Shown when a sensitive action needs a device passcode that isn't set.
    static var passcodeRequiredMessage: String {
        let pane = biometryName == "passcode" ? "Passcode" : "\(biometryName) & Passcode"
        return "This needs a device passcode, so that only you can approve it. Set a passcode in Settings → \(pane), then try again."
    }

    /// The name of this device's biometric unlock ("Face ID", "Touch ID",
    /// "Optic ID"), or "passcode" when no biometry is available.
    static var biometryName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "passcode"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "passcode"
        }
    }

    /// True when the device has a passcode (and so can authenticate the owner).
    static var isPasscodeSet: Bool {
        var error: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return true }
        // Lockout or biometry errors still mean a passcode exists.
        return (error as? LAError)?.code != .passcodeNotSet
    }

    /// Asks the device owner to authenticate (biometrics, falling back to the
    /// passcode).
    ///
    /// - Parameter requirePasscode: With no passcode set there is nothing to
    ///   authenticate against. App lock and chat lock let the user through in
    ///   that case; actions that must prove the owner is present (device-linking
    ///   approval, emergency wipe) pass `true` so they fail instead. Check
    ///   `isPasscodeSet` first to explain why.
    static func authenticate(reason: String, requirePasscode: Bool = false) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        // `.deviceOwnerAuthentication` falls back to the passcode, so a phone without
        // biometrics enrolled, or locked out after failed attempts, can still get in.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if (error as? LAError)?.code == .passcodeNotSet {
                return !requirePasscode
            }
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
