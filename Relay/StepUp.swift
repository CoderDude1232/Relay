//
//  StepUp.swift
//  Relay
//
//  "Confirm it's you": before a sensitive change on an account with two-step
//  verification (linking a device, adding a passkey or number, turning
//  two-step or device regions off, showing the recovery key), the device
//  answers the second step again. Someone with a few minutes on an unlocked
//  phone, or a device they linked, doesn't know it. The relay enforces it for
//  its own settings (a 403 asks; RelayAPIClient calls `confirm()` and
//  retries); settings only the devices know ask here first.
//

import RelayKit
import SwiftUI

@MainActor @Observable
final class StepUpCoordinator {
    static let shared = StepUpCoordinator()

    /// The challenge being shown.
    private(set) var challenge: StepUpChallenge?
    @ObservationIgnored var api: RelayAPIClient?
    @ObservationIgnored private var waiting: [CheckedContinuation<Bool, Never>] = []

    /// True once this device has answered (or the account has no second
    /// step); false if cancelled or unreachable.
    func confirm() async -> Bool {
        if challenge != nil {
            // Already asking: share that answer.
            return await withCheckedContinuation { waiting.append($0) }
        }
        guard let api else { return false }
        let fetched: StepUpChallenge?
        do {
            fetched = try await api.stepUpChallenge()
        } catch {
            return false
        }
        guard let fetched else { return true }
        guard let presenter = Self.topViewController() else { return false }
        let sheet = UIHostingController(rootView: StepUpSheet(challenge: fetched, api: api))
        // Cancel is the only way out: the caller waits for an answer.
        sheet.isModalInPresentation = true
        presented = sheet
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            challenge = fetched
            presenter.present(sheet, animated: true)
        }
    }

    func finish(_ passed: Bool) {
        challenge = nil
        presented?.dismiss(animated: true)
        presented = nil
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume(returning: passed) }
    }

    // Presented with UIKit over whatever is on top, since the change may come
    // from a sheet (linking a device) that SwiftUI couldn't stack another on.
    @ObservationIgnored private var presented: UIViewController?
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// Asks for the account's second step, or the recovery key instead.
struct StepUpSheet: View {
    let challenge: StepUpChallenge
    let api: RelayAPIClient

    @State private var answer = ""
    @State private var recoveryKey = ""
    @State private var usingRecoveryKey = false
    /// Which of the account's methods is being answered.
    @State private var chosen: TwoStepRequired.Method?
    @State private var pinHasLetters = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var passkeys = PasskeyAuthenticator()
    @FocusState private var focused: Bool

    private var method: TwoStepRequired.Method? {
        usingRecoveryKey ? .recovery : (chosen ?? challenge.methods.first ?? challenge.method)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsHero(systemName: heroIcon, color: heroColor, title: "Confirm It's You", message: footer)
                        .settingsBareRow()
                }
                switch method {
                case .authenticator:
                    Section {
                        TextField("6-digit code", text: $answer)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focused)
                            .onChange(of: answer) { _, new in
                                let digits = String(new.filter(\.isNumber).prefix(6))
                                if digits != new { answer = digits; return }
                                if digits.count == 6 { submit() }
                            }
                    } footer: { errorFooter }
                case .pin:
                    Section {
                        SecureField(pinHasLetters ? "Password" : "PIN", text: $answer)
                            .keyboardType(pinHasLetters ? .default : .numberPad)
                            .textContentType(.password)
                            .focused($focused)
                            .onSubmit { submit() }
                            .id(pinHasLetters)
                    } footer: { errorFooter }
                case .passkey:
                    if errorMessage != nil {
                        Section {} footer: { errorFooter }
                    }
                case .recovery, nil:
                    Section {
                        TextField("Recovery key", text: $recoveryKey)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .focused($focused)
                    } footer: { errorFooter }
                }
                Section {
                    SettingsPrimaryButton(title: method == .passkey ? "Use Passkey" : "Confirm",
                                          systemName: method == .passkey ? "person.badge.key.fill" : nil,
                                          color: heroColor, working: working) { submit() }
                        .disabled(!(method == .passkey || canSubmit))
                        .settingsBareRow()
                }
                let others = usingRecoveryKey ? [] : challenge.methods.filter { $0 != method && $0 != .recovery }
                let offerRecovery = !usingRecoveryKey && challenge.method != .recovery && challenge.method != nil
                if method == .pin || !others.isEmpty || offerRecovery {
                    Section {
                        if method == .pin {
                            Button(pinHasLetters ? "Use a number PIN" : "My PIN has letters") {
                                pinHasLetters.toggle()
                                answer = ""
                                Task { focused = true }
                            }
                        }
                        ForEach(others, id: \.self) { other in
                            Button(TwoStepRequired.Method.useInsteadTitle(other)) {
                                chosen = other
                                answer = ""
                                errorMessage = nil
                                Task { focused = true }
                            }
                        }
                        if offerRecovery {
                            Button("Use your recovery key instead") {
                                usingRecoveryKey = true
                                errorMessage = nil
                                Task { focused = true }
                            }
                        }
                    }
                    .tint(.primary)
                    .disabled(working)
                }
            }
            .navigationTitle("Confirm It's You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { StepUpCoordinator.shared.finish(false) }
                        .disabled(working)
                }
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var errorFooter: some View {
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
    }

    private var heroIcon: String {
        switch method {
        case .authenticator: "lock.rotation"
        case .pin: "circle.grid.3x3.fill"
        case .passkey: "person.badge.key.fill"
        case .recovery, nil: "key.fill"
        }
    }

    private var heroColor: Color {
        switch method {
        case .authenticator: .indigo
        case .pin: .orange
        case .passkey: .teal
        case .recovery, nil: .yellow
        }
    }

    private var footer: String {
        switch method {
        case .authenticator: "Enter the code from your authenticator app to make this change."
        case .pin: "Enter your PIN to make this change."
        case .passkey: "Use one of your passkeys to make this change."
        case .recovery, nil: "Enter your recovery key to make this change."
        }
    }

    private var canSubmit: Bool {
        method == .recovery || method == nil ? RecoveryKey.isPlausible(recoveryKey) : !answer.isEmpty
    }

    private func submit() {
        guard !working else { return }
        working = true
        errorMessage = nil
        Task {
            do {
                switch method {
                case .authenticator:
                    try await api.verifyStepUp(ticket: challenge.ticket, answer: .code(answer))
                case .pin:
                    let entered = answer
                    try await AccountPasswordKey.checking(entered) { proof in
                        try await api.verifyStepUp(ticket: challenge.ticket, answer: .pin(proof))
                    }
                case .passkey:
                    guard let nonce = challenge.challenge else { throw PasskeyError.failed("This account has no passkey. Use your recovery key.") }
                    let a = try await passkeys.assert(challenge: nonce)
                    try await api.verifyStepUp(ticket: challenge.ticket, answer: .passkey(
                        credentialId: a.credentialId, clientDataJSON: a.clientDataJSON,
                        authenticatorData: a.authenticatorData, signature: a.signature, userHandle: a.userHandle))
                case .recovery, nil:
                    try await api.verifyStepUp(recoveryAuthKey: RecoveryKey.authKey(recoveryKey))
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                StepUpCoordinator.shared.finish(true)
            } catch PasskeyError.canceled {
            } catch RelayAPIError.http(401, let message) where message.contains("expired") {
                errorMessage = "This took too long. Cancel and try the change again."
            } catch RelayAPIError.http(401, _) {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                errorMessage = "That isn't right. Check it and try again."
                answer = ""
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}
