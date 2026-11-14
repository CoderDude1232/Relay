//
//  PinLockManager.swift
//  Relay
//
//  The Relay PIN lock and distress PIN (docs/DISTRESS_PIN_PLAN.md).
//
//  - Ask: whenever Relay leaves the screen, its PIN is needed to come back.
//    Checked on this iPhone (PBKDF2 + backoff); the data stays readable here.
//  - Forget: whenever Relay leaves the screen, the database key is deleted
//    (SecureStorage/PinLock.swift) and the PIN is the only way back. The relay
//    answers the PIN without seeing it and deletes its half after 10 wrong
//    ones, so "forgetting the PIN" erases the messages.
//
//  iOS doesn't tell a suspended app that the phone locked, so both modes lock
//  when Relay goes to the background (not during a call).
//
//  The distress PIN is checked here first, before anything goes to the relay:
//  it deletes the relay's key, sends the emergency wipe to every device and
//  erases this one, ending on the sign-up screen.
//

import Foundation
import Observation
import RelayKit
import SecureStorage

enum PinLockMode: String, CaseIterable, Identifiable {
    case off, ask, forget
    var id: String { rawValue }
}

enum PinUnlockResult: Equatable {
    case unlocked
    case wrong(attemptsLeft: Int?)
    case waitUntil(Date)
    case needsInternet
    /// The relay no longer has the key: the messages here can't be opened.
    case erased
    case failed(String)
}

@MainActor
@Observable
final class PinLockManager {
    static let shared = PinLockManager()

    private(set) var mode: PinLockMode
    /// The PIN screen is up.
    private(set) var isLocked: Bool
    private(set) var hasDistressPin: Bool

    private static let modeKey = "relay.pinLock.mode"

    // Keychain items (the shared Keychain service, so a full wipe removes them).
    private enum Item {
        /// salt ‖ PBKDF2(PIN): the "ask" mode check.
        static let pinCheck = "pin-lock.pin-check"
        /// salt ‖ PBKDF2(distress PIN)
        static let distressCheck = "pin-lock.distress-check"
        static let failures = "pin-lock.failures"
        static let lockedUntil = "pin-lock.locked-until"
    }

    /// Wrong PINs allowed before backoff ("ask" mode), then 30 s doubling to an hour.
    private static let freeAttempts = 3
    private static let baseLockout: TimeInterval = 30
    private static let maxLockout: TimeInterval = 3600

    private var keychain: KeychainSecureStore {
        KeychainSecureStore(configuration: KeychainConfiguration(accessGroup: AppModel.appGroupId))
    }

    init() {
        let mode = PinLockMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .off
        self.mode = mode
        // Every launch starts locked: the last session may have ended anywhere.
        isLocked = mode != .off
        hasDistressPin = false
        hasDistressPin = (try? keychain.loadSecret(for: Item.distressCheck)) != nil
    }

    func showLock() { if mode != .off { isLocked = true } }

    // MARK: - Locking

    /// Relay left the screen.
    func didEnterBackground(model: AppModel, inCall: Bool) {
        guard mode != .off, !inCall else { return }
        if mode == .forget, model.isReady {
            do {
                try model.lockForPin()
            } catch {
                // No sealed copy to come back from: never delete the key then.
                return
            }
        }
        isLocked = true
    }

    // MARK: - Unlocking

    func unlock(pin: String, model: AppModel) async -> PinUnlockResult {
        if await matchesDistress(pin) {
            await performDistress(model: model)
            return .unlocked
        }
        switch mode {
        case .off:
            isLocked = false
            return .unlocked
        case .ask:
            return await unlockAsk(pin)
        case .forget:
            return await unlockForget(pin, model: model)
        }
    }

    private func unlockAsk(_ pin: String) async -> PinUnlockResult {
        if let until = currentLockout() { return .waitUntil(until) }
        guard await Self.matches(pin, check: try? keychain.loadSecret(for: Item.pinCheck)) else {
            if let until = recordFailure() { return .waitUntil(until) }
            return .wrong(attemptsLeft: nil)
        }
        resetFailures()
        isLocked = false
        return .unlocked
    }

    private func unlockForget(_ pin: String, model: AppModel) async -> PinUnlockResult {
        let keychain = self.keychain
        guard let api = model.lockedAPIClient(),
              let stored = try? keychain.sealedDatabaseKey() else {
            return .failed("Relay couldn't find its locked data.")
        }
        let blinded: PinLockCrypto.Blinded
        do {
            let stretched = try await Self.offMain { try PinLockCrypto.stretch(pin: pin, salt: stored.salt) }
            blinded = try PinLockCrypto.blind(stretched: stretched)
        } catch {
            return .failed("Relay couldn't check the PIN.")
        }
        let answer: PinGuardResult
        do {
            answer = try await api.evaluatePinGuard(blinded: blinded.element)
        } catch {
            return .needsInternet
        }
        switch answer {
        case .noKey, .exhausted:
            // The relay's half is gone, so nothing here can be opened again.
            model.wipeForDistress()
            isLocked = false
            return .erased
        case .evaluated(let evaluated, let attemptsLeft):
            do {
                let output = try PinLockCrypto.unblind(blinded, evaluated: evaluated)
                let keys = PinLockCrypto.keys(oprfOutput: output, deviceSecret: try keychain.pinLockDeviceSecret(),
                                              salt: stored.salt)
                do {
                    try keychain.restoreDatabaseKey(kek: keys.kek)
                } catch PinLockError.sealedKeyDidNotOpen {
                    return .wrong(attemptsLeft: attemptsLeft)
                }
                // Resets the relay's count; if this fails the next unlock still
                // works, it just starts with fewer attempts.
                Task { _ = try? await api.confirmPinGuard(verifier: keys.verifier) }
                isLocked = false
                await model.unlockedByPin()
                return .unlocked
            } catch {
                return .failed("Relay couldn't open its data.")
            }
        }
    }

    // MARK: - Distress

    private func matchesDistress(_ pin: String) async -> Bool {
        await Self.matches(pin, check: try? keychain.loadSecret(for: Item.distressCheck))
    }

    /// Deletes the relay's key and sends the emergency wipe while the Keychain
    /// still holds what they need, then erases this iPhone. Gives the relay a
    /// few seconds; offline, only this iPhone is erased.
    private func performDistress(model: AppModel) async {
        let keychain = self.keychain
        if let api = model.lockedAPIClient(), let credentials = model.lockedCredentials {
            let remote = Task {
                try? await api.deletePinGuard()
                try? await MessagingService.sendNukeCommand(api: api, keychain: keychain, credentials: credentials)
            }
            let timeout = Task { try? await Task.sleep(for: .seconds(6)); remote.cancel() }
            _ = await remote.value
            timeout.cancel()
        }
        setMode(.off)
        hasDistressPin = false
        isLocked = false
        model.wipeForDistress()
    }

    // MARK: - Setting up

    enum SetupError: LocalizedError {
        case sameAsDistress, noService, failed(String)
        var errorDescription: String? {
            switch self {
            case .sameAsDistress: "The distress PIN must be different from your Relay PIN."
            case .noService: "Relay isn't ready yet. Try again in a moment."
            case .failed(let message): message
            }
        }
    }

    /// Turns the lock on in `mode` with `pin`, or changes the PIN. Forget mode
    /// talks to the relay, so it needs internet.
    func setUp(mode newMode: PinLockMode, pin: String, model: AppModel) async throws {
        guard case .ready(let service) = model.phase else { throw SetupError.noService }
        if await matchesDistress(pin) { throw SetupError.sameAsDistress }
        let keychain = self.keychain
        switch newMode {
        case .off:
            try await turnOff(model: model)
            return
        case .ask:
            if mode == .forget { try await removeForget(api: service.apiClient) }
            try keychain.storeSecret(try await Self.makeCheck(pin), for: Item.pinCheck)
        case .forget:
            let api = service.apiClient
            do {
                try await enrolForget(pin: pin, api: api)
            } catch {
                // Enrolment replaced the relay's key, so an earlier sealed copy
                // no longer opens. Turn the lock off rather than leave a copy
                // that would look like an erased key at the next unlock.
                try? keychain.removePinLock()
                try? await api.deletePinGuard()
                setMode(.off)
                throw error
            }
            try? keychain.deleteSecret(for: Item.pinCheck)
        }
        resetFailures()
        setMode(newMode)
    }

    private func enrolForget(pin: String, api: RelayAPIClient) async throws {
        let keychain = self.keychain
        let salt = PinLockCrypto.newSalt()
        let stretched = try await Self.offMain { try PinLockCrypto.stretch(pin: pin, salt: salt) }
        let blinded = try PinLockCrypto.blind(stretched: stretched)
        let evaluated: Data
        do {
            evaluated = try await api.enrolPinGuard(blinded: blinded.element)
        } catch {
            throw SetupError.failed("Turning this on needs an internet connection.")
        }
        let output = try PinLockCrypto.unblind(blinded, evaluated: evaluated)
        let keys = PinLockCrypto.keys(oprfOutput: output, deviceSecret: try keychain.pinLockDeviceSecret(), salt: salt)
        let databaseKey = try keychain.databaseKey()
        let sealed = try PinLockCrypto.seal(databaseKey.bytes, with: keys.kek)
        // Never rely on a sealed copy that doesn't open.
        guard try PinLockCrypto.open(sealed, with: keys.kek) == databaseKey.bytes else {
            throw SetupError.failed("Relay couldn't lock its data.")
        }
        do {
            try await api.setPinGuardVerifier(keys.verifier)
        } catch {
            throw SetupError.failed("Turning this on needs an internet connection.")
        }
        try keychain.storeSealedDatabaseKey(sealed, salt: salt)
    }

    func turnOff(model: AppModel) async throws {
        if mode == .forget, case .ready(let service) = model.phase {
            try await removeForget(api: service.apiClient)
        }
        try? keychain.deleteSecret(for: Item.pinCheck)
        resetFailures()
        setMode(.off)
        isLocked = false
    }

    private func removeForget(api: RelayAPIClient) async throws {
        try keychain.removePinLock()
        try? await api.deletePinGuard()
    }

    func setDistressPin(_ pin: String?) async throws {
        guard let pin else {
            try keychain.deleteSecret(for: Item.distressCheck)
            hasDistressPin = false
            return
        }
        if mode == .ask, await Self.matches(pin, check: try? keychain.loadSecret(for: Item.pinCheck)) {
            throw SetupError.sameAsDistress
        }
        try keychain.storeSecret(try await Self.makeCheck(pin), for: Item.distressCheck)
        hasDistressPin = true
    }

    private func setMode(_ newMode: PinLockMode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
    }

    // MARK: - On-device checks

    private static func makeCheck(_ pin: String) async throws -> Data {
        let salt = PinLockCrypto.newSalt()
        let digest = try await offMain { try PinLockCrypto.stretch(pin: pin, salt: salt) }
        return salt + digest
    }

    private static func matches(_ pin: String, check: Data?) async -> Bool {
        guard let check, check.count == PinLockCrypto.saltSize + 32 else { return false }
        let salt = Data(check.prefix(PinLockCrypto.saltSize))
        let expected = Data(check.suffix(32))
        guard let digest = try? await offMain({ try PinLockCrypto.stretch(pin: pin, salt: salt) }) else { return false }
        return PinLockCrypto.equal(digest, expected)
    }

    /// PBKDF2's 600k rounds take a few tenths of a second: not on the main thread.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func currentLockout() -> Date? {
        guard let raw = try? keychain.loadSecret(for: Item.lockedUntil),
              let seconds = Double(String(decoding: raw, as: UTF8.self)) else { return nil }
        let until = Date(timeIntervalSince1970: seconds)
        return until > Date() ? until : nil
    }

    private func recordFailure() -> Date? {
        let raw = try? keychain.loadSecret(for: Item.failures)
        let failures = (raw.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0) + 1
        try? keychain.storeSecret(Data(String(failures).utf8), for: Item.failures)
        guard failures > Self.freeAttempts else { return nil }
        let lockout = min(Self.baseLockout * pow(2, Double(failures - Self.freeAttempts - 1)), Self.maxLockout)
        let until = Date().addingTimeInterval(lockout)
        try? keychain.storeSecret(Data(String(until.timeIntervalSince1970).utf8), for: Item.lockedUntil)
        return until
    }

    private func resetFailures() {
        try? keychain.deleteSecret(for: Item.failures)
        try? keychain.deleteSecret(for: Item.lockedUntil)
    }
}
