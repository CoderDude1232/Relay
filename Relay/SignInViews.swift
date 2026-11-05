//
//  SignInViews.swift
//  Relay
//
//  The onboarding screens for the simplified account model: sign in (or up)
//  with a phone number, the second step a code sign-in can ask for, and the
//  list of ways back into an existing account. Same look as OnboardingView.
//

import RelayKit
import SwiftUI

// MARK: - Shared pieces
// The sign-in screens' building blocks, drawn with the DSComponents look.

struct OnboardingBackButton: View {
    let action: () -> Void
    var body: some View {
        HStack {
            Button(action: action) {
                Label("Back", systemImage: "chevron.left")
                    .font(.body)
                    .labelStyle(.titleAndIcon)
            }
            .tint(.accentColor)
            .frame(minHeight: 44)
            Spacer()
        }
        .padding(.top, DS.Spacing.sm)
    }
}

/// A page headline: the last word in pink, as `DSHeadline` draws it.
struct OnboardingHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        let words = title.split(separator: " ")
        DSHeadline(title: words.dropLast().joined(separator: " "),
                   accent: words.last.map(String.init),
                   subtitle: subtitle)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xs)
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    var enabled = true
    var working = false
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.dsPrimary(working: working))
            .disabled(!enabled || working)
    }
}

/// A row in a card: an icon, then the field or label.
struct OnboardingRow<Content: View>: View {
    let icon: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, 14)
    }
}

extension View {
    /// The grouped card behind a set of rows.
    func onboardingCard() -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

/// A full-width choice on the sign-in list.
private struct ChoiceButton: View {
    let title: String
    let subtitle: String
    let icon: String
    var color: Color = .accentColor
    var working = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                DSRowLabel(title, subtitle: subtitle, icon: icon, color: color)
                if working {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .dsRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }
}

// MARK: - Sign in to an existing account

/// Every way back in. Phone, email, Apple and Google also create an account
/// when there isn't one, so they're on the welcome screen too.
struct SignInOptionsView: View {
    let onPhone: () -> Void
    let onEmail: () -> Void
    let onBack: () -> Void

    @Environment(AppModel.self) private var model
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showingRecoveryKey = false
    @State private var showingReviewCode = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                OnboardingBackButton(action: onBack)
                OnboardingHeader(title: "Sign in", subtitle: "Signing in here signs your other devices out.")

                DSGroup {
                    ChoiceButton(title: "Passkey", subtitle: "Face ID or Touch ID, no code needed", icon: "person.badge.key.fill",
                                 color: .green, working: working) { passkey() }
                    ChoiceButton(title: "Phone number", subtitle: "We'll text you a code", icon: "phone.fill",
                                 color: .blue, action: onPhone)
                    ChoiceButton(title: "Email", subtitle: "We'll email you a code", icon: "envelope.fill",
                                 color: .orange, action: onEmail)
                    ChoiceButton(title: "Recovery key", subtitle: "The key you saved when you signed up", icon: "key.horizontal.fill",
                                 color: .gray) {
                        showingRecoveryKey = true
                    }
                }

                if let errorMessage { InlineErrorBanner(errorMessage) }

                Text("Signed up with Apple or Google? Go back and use the same button.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Button("Review Code") { showingReviewCode = true }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingRecoveryKey) { RecoveryKeySignInSheet() }
        .sheet(isPresented: $showingReviewCode) { ReviewCodeSheet() }
    }

    private func passkey() {
        working = true
        errorMessage = nil
        Task {
            do {
                try await model.signInWithPasskey(autoFill: false)
            } catch PasskeyError.canceled {
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}

// MARK: - Phone number

/// A number, then the texted code. An existing account signs in (maybe asking
/// for its second step); a new number goes on to pick a username.
struct PhoneSignInView: View {
    let onNewAccount: (_ phone: String, _ signupTicket: String) -> Void
    let onTwoStep: (AppModel.TwoStepNeededError) -> Void
    let onBack: () -> Void

    @Environment(AppModel.self) private var model
    @State private var country = PhoneNumbers.defaultCountry
    @State private var number = ""
    @State private var code = ""
    @State private var pendingNumber: String?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var resendNote: String?
    @FocusState private var focused: Field?

    private enum Field: Hashable { case number, code }
    private static let codeLength = 6

    private var typedNumber: String? { PhoneNumbers.e164(number, country: country) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                OnboardingBackButton {
                    if pendingNumber != nil {
                        pendingNumber = nil
                        code = ""
                        errorMessage = nil
                        resendNote = nil
                    } else {
                        onBack()
                    }
                }
                if let pendingNumber {
                    codeStep(pendingNumber)
                } else {
                    numberStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: code) { _, new in
            let digits = String(new.filter(\.isNumber).prefix(Self.codeLength))
            if digits != new { code = digits; return }
            if digits.count == Self.codeLength { verify() }
        }
    }

    private var numberStep: some View {
        VStack(spacing: 16) {
            OnboardingHeader(title: "Your phone number",
                             subtitle: "We'll text you a code. New here? This creates your account.")
            VStack(spacing: 0) {
                OnboardingRow(icon: "globe") {
                    Menu {
                        Picker("Country", selection: $country) {
                            ForEach(PhoneNumbers.countries) { c in
                                Text("\(c.flag) \(c.name) (+\(c.callingCode))").tag(c)
                            }
                        }
                    } label: {
                        HStack {
                            Text("\(country.flag) \(country.name)").foregroundStyle(Color(.label))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(.secondaryLabel))
                        }
                    }
                    .accessibilityLabel("Country, \(country.name)")
                }
                Divider()
                OnboardingRow(icon: "phone") {
                    Text("+\(country.callingCode)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    TextField("Phone number", text: $number)
                        .focused($focused, equals: .number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .tint(.accentColor)
                }
                .contentShape(.rect)
                .onTapGesture { focused = .number }
            }
            .onboardingCard()

            if let errorMessage { InlineErrorBanner(errorMessage) }

            OnboardingPrimaryButton(title: "Send code", enabled: typedNumber != nil, working: working) { sendCode() }

            Text("Your number is never shown to anyone. Standard text rates may apply.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            LegalFooter().padding(.horizontal, 16)
        }
        .onAppear { focused = .number }
    }

    private func codeStep(_ phone: String) -> some View {
        VStack(spacing: 16) {
            OnboardingHeader(title: "Check your messages",
                             subtitle: "Enter the code we texted to \(PhoneNumbers.display(phone)).")
            OnboardingRow(icon: "number") {
                TextField("Code", text: $code)
                    .focused($focused, equals: .code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .foregroundStyle(.primary)
                    .tint(.accentColor)
            }
            .contentShape(.rect)
            .onTapGesture { focused = .code }
            .onboardingCard()
            .onAppear { focused = .code }

            if let errorMessage { InlineErrorBanner(errorMessage) }

            OnboardingPrimaryButton(title: "Continue", enabled: code.count == Self.codeLength, working: working) { verify() }

            Button("Resend code") { sendCode(resending: true) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .disabled(working)
            if let resendNote {
                Text(resendNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func sendCode(resending: Bool = false) {
        guard let phone = resending ? pendingNumber : typedNumber else { return }
        focused = nil
        resendNote = nil
        run {
            try await model.requestPhoneCode(phone)
            code = ""
            pendingNumber = phone
            focused = .code
            if resending { resendNote = "Sent. It can take a minute to arrive." }
        }
    }

    private func verify() {
        guard let phone = pendingNumber, code.count == Self.codeLength, !working else { return }
        let entered = code
        run(onError: { code = "" }) {
            do {
                switch try await model.signInWithPhone(phone, code: entered) {
                case .signedIn:
                    break // phase = .ready dismisses onboarding
                case .newAccount(let ticket):
                    onNewAccount(phone, ticket)
                }
            } catch let needed as AppModel.TwoStepNeededError {
                onTwoStep(needed)
            }
        }
    }

    private func run(onError: @escaping () -> Void = {}, _ action: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            do {
                try await action()
            } catch {
                onError()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                if let retry = (error as? RelayAPIError).flatMap(Self.retryAfter) {
                    errorMessage = "Wait \(retry) before asking for another code."
                } else {
                    errorMessage = FriendlyError.message(for: error)
                }
            }
            working = false
        }
    }

    private static func retryAfter(_ error: RelayAPIError) -> String? {
        guard case .rateLimited(_, let seconds?) = error, seconds <= 120 else { return nil }
        let s = Int(seconds.rounded(.up))
        return s == 1 ? "a second" : "\(s) seconds"
    }
}

// MARK: - Second step

extension TwoStepRequired.Method {
    /// The link that switches a second-step screen to this method.
    static func useInsteadTitle(_ method: Self) -> String {
        switch method {
        case .authenticator: "Use your authenticator app instead"
        case .passkey: "Use a passkey instead"
        case .pin: "Use your PIN instead"
        case .recovery: "Use your recovery key instead"
        }
    }
}

/// The account asked for its second step after an email, Apple, Google or
/// phone sign-in. The recovery key always works instead.
struct TwoStepView: View {
    let needed: AppModel.TwoStepNeededError
    /// The ticket expired: start the sign-in again.
    let onRestart: () -> Void

    @Environment(AppModel.self) private var model
    @State private var answer = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showingRecoveryKey = false
    @State private var pinHasLetters = false
    /// Which of the account's methods is being answered.
    @State private var chosen: TwoStepRequired.Method?
    @FocusState private var focused: Bool

    private var method: TwoStepRequired.Method? { chosen ?? needed.challenge.methods.first ?? needed.challenge.method }

    private var title: String {
        method == .recovery || method == nil ? "Recovery key" : "Two-step verification"
    }

    private var subtitle: String {
        switch method {
        case .authenticator: "Enter the code from your authenticator app to finish signing in and restore your messages."
        case .passkey: "Use your passkey to finish signing in and restore your messages."
        case .pin: "Enter your PIN to finish signing in and restore your messages."
        case .recovery, nil: "Enter your recovery key to finish signing in and restore your messages."
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                OnboardingBackButton(action: onRestart)
                OnboardingHeader(title: title, subtitle: subtitle)

                switch method {
                case .authenticator:
                    OnboardingRow(icon: "lock.rotation") {
                        TextField("6-digit code", text: $answer)
                            .focused($focused)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .foregroundStyle(.primary)
                            .tint(.accentColor)
                    }
                    .onboardingCard()
                    .onChange(of: answer) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { answer = digits; return }
                        if digits.count == 6 { submit(.code(digits)) }
                    }
                    errorBanner
                    OnboardingPrimaryButton(title: "Continue", enabled: answer.count == 6, working: working) {
                        submit(.code(answer))
                    }
                case .pin:
                    OnboardingRow(icon: "lock") {
                        SecureField(pinHasLetters ? "Password" : "PIN", text: $answer)
                            .focused($focused)
                            .keyboardType(pinHasLetters ? .default : .numberPad)
                            .textContentType(.password)
                            .foregroundStyle(.primary)
                            .tint(.accentColor)
                            .onSubmit { submit(.pin(answer)) }
                            // A new keyboard type only shows on refocus.
                            .id(pinHasLetters)
                    }
                    .onboardingCard()
                    errorBanner
                    OnboardingPrimaryButton(title: "Continue", enabled: !answer.isEmpty, working: working) {
                        submit(.pin(answer))
                    }
                    // Accounts from before PINs set an account password, which can
                    // have letters.
                    Button(pinHasLetters ? "Use a number PIN" : "My PIN has letters") {
                        pinHasLetters.toggle()
                        answer = ""
                        Task { focused = true }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                    .disabled(working)
                case .passkey:
                    errorBanner
                    OnboardingPrimaryButton(title: "Use Passkey", working: working) { submit(.passkey) }
                case .recovery, nil:
                    errorBanner
                    OnboardingPrimaryButton(title: "Enter Recovery Key") { showingRecoveryKey = true }
                }

                ForEach(needed.challenge.methods.filter { $0 != method && $0 != .recovery }, id: \.self) { other in
                    Button(TwoStepRequired.Method.useInsteadTitle(other)) {
                        chosen = other
                        answer = ""
                        errorMessage = nil
                        Task { focused = true }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                    .disabled(working)
                }

                if method != .recovery, method != nil, needed.challenge.recoveryKey {
                    Button("Use your recovery key instead") { showingRecoveryKey = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 44)
                        .disabled(working)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = true }
        .sheet(isPresented: $showingRecoveryKey) { RecoveryKeySignInSheet() }
    }

    @ViewBuilder private var errorBanner: some View {
        if let errorMessage { InlineErrorBanner(errorMessage) }
    }

    private func submit(_ input: AppModel.TwoStepInput) {
        guard !working else { return }
        working = true
        errorMessage = nil
        focused = false
        Task {
            do {
                try await model.completeTwoStep(needed, with: input)
            } catch PasskeyError.canceled {
            } catch let failed as AppModel.TwoStepFailedError where failed.expired {
                onRestart()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                errorMessage = FriendlyError.message(for: error)
                answer = ""
                focused = true
            }
            working = false
        }
    }
}
