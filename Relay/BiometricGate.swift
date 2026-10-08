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
        // Locked out / biometry problems still mean a passcode exists.
        return (error as? LAError)?.code != .passcodeNotSet
    }

    /// Asks the device owner to authenticate (Face ID / Touch ID, falling back
    /// to the passcode).
    ///
    /// - Parameter requirePasscode: With no passcode set there is nothing to
    ///   authenticate against. For app lock / chat lock that means there is
    ///   nothing to protect, so the default lets the user through. Pass `true`
    ///   for actions that must prove the owner is present — device-linking
    ///   approval, emergency wipe — so they FAIL when no passcode is set
    ///   (check `isPasscodeSet` first to explain why).
    static func authenticate(reason: String, requirePasscode: Bool = false) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        // `.deviceOwnerAuthentication` falls back to the device passcode, so a
        // phone without Face ID enrolled — or locked out after failed attempts —
        // can still get in. Biometrics-only would lock the user out of their
        // own media and chats with no way back.
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
