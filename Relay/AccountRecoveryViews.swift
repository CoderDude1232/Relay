//
//  AccountRecoveryViews.swift
//  Relay
//
//  Email-free sign-up, the recovery key (sign-in, viewing, saving) and email
//  removal, each with its trade-offs spelled out.
//

import RelayKit
import SwiftUI

// MARK: - Trade-offs

/// One trade-off line: a symbol and a sentence.
private struct TradeoffRow: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct NoEmailTradeoffs: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TradeoffRow(symbol: "checkmark.shield.fill", tint: .green,
                        text: "Nothing that identifies you is stored: no email, and no sign-in provider ever sees you.")
            TradeoffRow(symbol: "person.badge.key.fill", tint: .green,
                        text: "You sign in with a passkey, which syncs to your other Apple devices through iCloud Keychain.")
            TradeoffRow(symbol: "key.horizontal.fill", tint: .orange,
                        text: "Your recovery key is the only backup. Keep it somewhere safe, like a password manager or on paper.")
            TradeoffRow(symbol: "exclamationmark.triangle.fill", tint: .red,
                        text: "There's no \"forgot password\" by email. If you lose your passkey and your recovery key, the account can't be recovered by anyone, including us.")
        }
    }
}

// MARK: - Sign up without email (onboarding)

struct PasskeySignupIntroView: View {
    let onContinue: () -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.top, 16)

                VStack(spacing: 6) {
                    Text("No email")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Just a username and a passkey.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                NoEmailTradeoffs()
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(20)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))

                Button(action: onContinue) {
                    Text("I Understand, Continue")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.06, green: 0.02, blue: 0.22))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
                }

                Text("You'll pick a username, then create a passkey with Face ID. We'll show you your recovery key straight after.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                Spacer().frame(height: 30)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Sign in with a recovery key

struct RecoveryKeySignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $key, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .accessibilityLabel("Recovery key")
                } footer: {
                    Text(errorMessage ?? "Signs in without your password or an email code, and brings back your chat list. Your other devices are signed out.")
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Sign In") { signIn() }.tint(.primary)
                            .bold()
                            .disabled(!RecoveryKey.isPlausible(key))
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }
        .presentationDetents([.medium])
    }

    private func signIn() {
        working = true
        errorMessage = nil
        Task {
            do {
                try await model.signInWithRecoveryKey(key)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}

// MARK: - Showing a key

struct RecoveryKeyCard: View {
    let key: String

    /// Three groups a line, so the key never wraps mid-way and leaves a
    /// dash hanging.
    static func lines(_ key: String) -> String {
        let groups = RecoveryKey.format(key).split(separator: "-")
        guard groups.count > 3 else { return RecoveryKey.format(key) }
        return groups.prefix(3).joined(separator: "-") + "\n" + groups.dropFirst(3).joined(separator: "-")
    }

    private var displayed: String { Self.lines(key) }

    var body: some View {
        VStack(spacing: 14) {
            Text(displayed)
                .font(.title3.monospaced().weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(RecoveryKey.format(key).map { String($0) }.joined(separator: " "))
            RecoveryKeyCopyButton(key: key)
        }
    }
}

struct RecoveryKeyCopyButton: View {
    let key: String
    @State private var copied = false

    var body: some View {
        Button {
            SecurePasteboard.copySecret(RecoveryKey.format(key))
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(.primary)
        }
        .buttonStyle(.bordered)
        .tint(.primary)
    }
}

/// Shown once after an email-free sign-up.
struct NewRecoveryKeySheet: View {
    let key: String
    let onDone: () -> Void
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("This is the only way back into your account if you lose your passkey. Store it somewhere safe: a password manager, or written down.")
                    RecoveryKeyCard(key: key)
                    Text("You can see it again any time in Settings → Account → Recovery Key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("I've saved my recovery key", isOn: $saved)
                }
                .padding(24)
            }
            .navigationTitle("Your Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).bold().disabled(!saved)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Settings → Account → Recovery Key

struct RecoveryKeyView: View {
    let service: MessagingService
    let methods: SignInMethods?
    @Environment(AppModel.self) private var model
    @State private var revealed: String?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showingEmailCode = false
    @State private var confirmingReplace = false

    private var email: String? { model.accountEmail }
    private var hasPasskey: Bool { (methods?.passkeys ?? 0) > 0 }
    private var hasKey: Bool { methods?.recoveryKey == true || service.recoveryKey != nil }
    /// With two-step on, its check is the one confirmation (a passkey can
    /// answer it); the other ways would only ask a second time.
    private var hasTwoStep: Bool {
        guard let on = methods?.twoStepMethods else { return false }
        return !on.isEmpty && on != [.recovery]
    }

    /// Random stand-in shown blurred until the key is revealed: the real key
    /// is never on screen (or in the view tree) while it's hidden.
    @State private var decoy = RecoveryKeyView.makeDecoy()

    private static func makeDecoy() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let groups = (0..<6).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }
        return groups.prefix(3).joined(separator: "-") + "\n" + groups.dropFirst(3).joined(separator: "-")
    }

    /// The first way this account can confirm it's you; the card's tap uses it.
    private var primaryReveal: (() async -> Void)? {
        if hasTwoStep { return { await reveal() } }
        if hasPasskey { return { await revealWithPasskey() } }
        if email != nil { return { showingEmailCode = true } }
        return { await revealWithDeviceOwner() }
    }

    private var revealHint: String {
        if !hasKey { return "Tap to Create" }
        if hasTwoStep { return "Tap to Reveal" }
        if hasPasskey { return "Tap to Reveal with Passkey" }
        if email != nil { return "Tap to Reveal with Email Code" }
        return "Tap to Reveal with \(BiometricGate.biometryName)"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.yellow.gradient, in: .rect(cornerRadius: 16))
                    Text(hasKey
                         ? "Your recovery key signs you in when you can't get a code or use a passkey, and brings back your chat list."
                         : "A recovery key signs you in when you can't get a code or use a passkey, and brings back your chat list.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    keyBox
                    if let revealed {
                        HStack(spacing: 12) {
                            RecoveryKeyCopyButton(key: revealed)
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) { self.revealed = nil }
                                decoy = Self.makeDecoy()
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.bordered)
                            .tint(.primary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            } footer: {
                Text(errorMessage ?? (revealed != nil
                    ? "Anyone with this key can sign in to your account, so keep it private: a password manager, or written down."
                    : "Only you can see it, after you confirm it's you."))
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }

            // Other ways to confirm, when the account has more than one.
            if revealed == nil, !hasTwoStep, hasPasskey, email != nil {
                Section {
                    Button { showingEmailCode = true } label: {
                        SettingsNavRow(systemName: "envelope.fill", color: .blue, title: "Use an Email Code Instead")
                    }
                    .tint(.primary)
                }
            }

            if revealed != nil {
                Section {
                    Button("Create New Key", role: .destructive) { confirmingReplace = true }
                } footer: {
                    Text("Makes a new key and stops the old one working.")
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Recovery Key")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingEmailCode) {
            if let email {
                EmailCodeConfirmSheet(email: email) { Task { await reveal() } }
            }
        }
        .confirmationDialog("Create a new recovery key?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Create New Key", role: .destructive) { Task { await create() } }
        } message: {
            Text("Your old key will stop working straight away.")
        }
    }

    private var keyBox: some View {
        let hidden = revealed == nil
        return Button {
            guard hidden, !working, let action = primaryReveal else { return }
            errorMessage = nil
            Task { await action() }
        } label: {
            Text(revealed.map(RecoveryKeyCard.lines) ?? decoy)
                .font(.title2.monospaced().weight(.semibold))
                .lineSpacing(6)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .blur(radius: hidden ? 6 : 0)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(.fill.tertiary, in: .rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    if hidden {
                        Group {
                            if working {
                                ProgressView()
                            } else {
                                Label(revealHint, systemImage: hasKey ? "eye.fill" : "plus")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassCompat(in: .capsule)
                        .transition(.opacity)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hidden ? revealHint : RecoveryKey.format(revealed ?? "").map { String($0) }.joined(separator: " "))
    }

    private func revealWithDeviceOwner() async {
        errorMessage = nil
        do {
            try await service.confirmOwner("Confirm it's you to see your recovery key.")
            await reveal()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func revealWithPasskey() async {
        errorMessage = nil
        do {
            try await model.confirmWithPasskey()
            await reveal()
        } catch PasskeyError.canceled {
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    /// Shows the key, making one only if the account has none. A key that
    /// exists but couldn't be loaded here (say, the chat list didn't download)
    /// is never silently replaced: the one the user wrote down would stop working.
    private func reveal() async {
        // Shows a key that signs in to the account: the second step too.
        guard await StepUpCoordinator.shared.confirm() else { return }
        if service.recoveryKey == nil { await service.restoreAccountStorage() }
        if let key = service.recoveryKey {
            withAnimation(.easeOut(duration: 0.4)) { revealed = key }
        } else if methods?.recoveryKey != false { // unknown counts as "has one"
            errorMessage = "Your recovery key couldn't be loaded on this device. Check your connection and try again, or create a new key (the old one will stop working)."
            confirmingReplace = true
        } else {
            await create()
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        do {
            let key = try await service.createRecoveryKey()
            withAnimation(.easeOut(duration: 0.4)) { revealed = key }
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}

/// Sends a sign-in code to the account's email and checks it.
private struct EmailCodeConfirmSheet: View {
    let email: String
    let onConfirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var sent = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                SettingsHero(systemName: sent ? "envelope.open.fill" : "envelope.fill", color: .blue,
                             title: sent ? "Check Your Email" : "Confirm It's You",
                             message: sent ? "We sent a code to \(email)." : "We'll email a code to \(email) to check it's you.")
                    .settingsBareRow()
            }
            if sent {
                Section {
                    TextField("Code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                } footer: {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            Section {
                if sent {
                    SettingsPrimaryButton(title: "Confirm", color: .blue, working: working) { Task { await verify() } }
                        .disabled(code.count < 6)
                        .settingsBareRow()
                } else {
                    SettingsPrimaryButton(title: "Send Code", color: .blue, working: working) { Task { await send() } }
                        .settingsBareRow()
                }
            } footer: {
                if !sent, let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Email Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        working = true
        defer { working = false }
        do {
            try await SignInAuth.shared.requestSignInCode(email: email)
            sent = true
            errorMessage = nil
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func verify() async {
        working = true
        defer { working = false }
        do {
            _ = try await SignInAuth.shared.verifySignInCode(email: email, code: code)
            dismiss()
            onConfirmed()
        } catch {
            errorMessage = "That code didn't work. Check it and try again."
        }
    }
}

// MARK: - Remove email

struct RemoveEmailSheet: View {
    let onRemoved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your email is deleted from Relay and from our sign-in provider. After this, a legal demand to either couldn't link your account to an email address.")
                    NoEmailTradeoffs()
                    TradeoffRow(symbol: "envelope.badge.shield.half.filled.fill", tint: .orange,
                                text: "Signing in with an email code, Apple or Google stops working for this account. Find Me by Email is turned off.")
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    SettingsPrimaryButton(title: "Remove My Email", systemName: "trash.fill", color: .red, working: working) {
                        Task { await remove() }
                    }
                    Text("You'll confirm with Face ID and your passkey. Make sure you've saved your recovery key first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Remove Email")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        errorMessage = nil
        do {
            try await model.removeEmail()
            dismiss()
            onRemoved()
        } catch PasskeyError.canceled {
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}

// MARK: - Unlock a backup this device can't open

/// The account has a backup but nothing on this device opens it (no iCloud
/// Keychain key for it, say on a new Apple ID). Uploads wait rather than
/// replace it, until it's unlocked with a passkey, the recovery key or the PIN.
struct BackupUnlockSheet: View {
    let service: MessagingService
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKey = ""
    @State private var pin = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsHero(systemName: "lock.open.fill", color: .blue, title: "Unlock Your Backup",
                                 message: "Your chat list and settings are backed up with your account, encrypted so only you can open them. Unlock it to bring them here and keep backing up.")
                        .settingsBareRow()
                    SettingsPrimaryButton(title: "Use Passkey", systemName: "person.badge.key.fill", color: .teal, working: working) {
                        unlock { try await model.unlockBackupWithPasskey() }
                    }
                    .settingsBareRow()
                }
                Section("Or Use Your Recovery Key") {
                    TextField("Recovery key", text: $recoveryKey)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button("Unlock with Recovery Key") {
                        let key = recoveryKey
                        unlock { await service.restoreAccountStorage(recoveryKey: key) }
                    }
                    .tint(.primary)
                    .disabled(!RecoveryKey.isPlausible(recoveryKey))
                }
                Section("Or Use Your PIN") {
                    SecureField("PIN", text: $pin)
                        .textContentType(.password)
                    Button("Unlock with PIN") {
                        let entered = pin
                        unlock { await service.unlockBackup(pin: entered) }
                    }
                    .tint(.primary)
                    .disabled(pin.isEmpty)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }.disabled(working)
                }
                if working {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func unlock(_ attempt: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            do {
                try await attempt()
                if service.backupNeedsUnlock {
                    errorMessage = "That didn't unlock it. Check it and try again."
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            } catch PasskeyError.canceled {
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}
