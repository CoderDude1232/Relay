//
//  PhoneNumberView.swift
//  Relay
//
//  The optional phone number, laid out like the onboarding screens: offered
//  once right after a new account, and opened from Profile → Account →
//  Phone Number. A number lets people who already have it find you. It's
//  verified once by text, never shown to anyone, and isn't a way to sign in.
//

import RelayKit
import SwiftUI

struct PhoneNumberView: View {
    enum Context { case onboarding, settings }

    let service: MessagingService
    let context: Context
    /// Skip, Done or Close.
    let onDone: () -> Void

    private enum Step: Hashable { case loading, unavailable, enterNumber, enterCode, added }

    @State private var step: Step = .loading
    @State private var country = PhoneNumbers.defaultCountry
    @State private var countries = PhoneNumbers.countries
    @State private var number = ""
    @State private var code = ""
    @State private var discoverable = true
    @State private var pendingNumber: String?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var resendNote: String?
    @State private var confirmingRemove = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case number, code }

    private static let codeLength = 6
    private static let ink = Color(red: 0.06, green: 0.02, blue: 0.22)

    private var savedNumber: String? { UserDefaults.standard.string(forKey: MessagingService.phoneNumberKey) }
    private var typedNumber: String? { PhoneNumbers.e164(number, country: country) }
    private var codeDigits: String { String(code.filter(\.isNumber).prefix(Self.codeLength)) }

    var body: some View {
        ZStack {
            BackgroundGradient()
            ScrollView {
                VStack(spacing: 16) {
                    topBar
                    Group {
                        switch step {
                        case .loading:
                            ProgressView().tint(.white).padding(.top, 120)
                        case .unavailable: unavailableStep
                        case .enterNumber: enterNumberStep
                        case .enterCode: enterCodeStep
                        case .added: addedStep
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(.spring(duration: 0.4), value: step)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .task { await load() }
        .onChange(of: code) { _, new in
            let digits = String(new.filter(\.isNumber).prefix(Self.codeLength))
            if digits != new { code = digits; return }
            if digits.count == Self.codeLength { verify() }
        }
        .confirmationDialog("Remove your phone number?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                run {
                    try await service.removePhone()
                    number = ""
                    step = .enterNumber
                }
            }
        } message: {
            Text("People who have your number won't be able to find you on Relay anymore. Your chats aren't affected.")
        }
    }

    // MARK: Pieces (the same look as OnboardingView's screens)

    private var topBar: some View {
        HStack {
            if step == .enterCode {
                circleButton("chevron.left", label: "Back") {
                    errorMessage = nil
                    resendNote = nil
                    step = .enterNumber
                }
            } else if context == .settings {
                circleButton("xmark", label: "Close", action: onDone)
            }
            Spacer()
            if context == .onboarding, step != .added {
                Button("Skip", action: onDone)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(minHeight: 40)
                    .disabled(working)
            }
        }
        .frame(minHeight: 40)
        .padding(.top, 16)
    }

    private func circleButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: .circle)
        }
        .accessibilityLabel(label)
        .disabled(working)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private func row<Content: View>(_ icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))
    }

    private var divider: some View { Divider().background(.white.opacity(0.12)) }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if working {
                    ProgressView().tint(Self.ink)
                } else {
                    Text(title).font(.headline).foregroundStyle(Self.ink)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(enabled && !working ? Color.white : Color.white.opacity(0.3),
                        in: .rect(cornerRadius: 16, style: .continuous))
        }
        .disabled(!enabled || working)
    }

    private func textButton(_ title: String, color: Color = .white.opacity(0.8), action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .disabled(working)
    }

    private var discoverableRow: some View {
        row("magnifyingglass") {
            Toggle("Find me by number", isOn: Binding(
                get: { discoverable },
                set: { on in
                    guard step == .added else { discoverable = on; return }
                    let previous = discoverable
                    discoverable = on
                    run(onError: { discoverable = previous }) { try await service.setPhoneDiscoverable(on) }
                }
            ))
            .foregroundStyle(.white)
            .tint(.accentColor)
        }
    }

    private var footnote: some View {
        Text("Never shown to anyone. Not used to sign in.")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var error: some View {
        if let errorMessage { InlineErrorBanner(errorMessage) }
    }

    // MARK: Steps

    private var unavailableStep: some View {
        VStack(spacing: 16) {
            header("Phone number", "Adding a phone number isn't available yet. You can add one later in Settings → Account.")
            primaryButton(context == .onboarding ? "Continue" : "Done", action: onDone)
        }
    }

    private var enterNumberStep: some View {
        VStack(spacing: 16) {
            header(savedNumber == nil ? "Phone number" : "New number",
                   "Optional. Friends with your number can find you.")

            card {
                if countries.count > 1 {
                    row("globe") {
                        Menu {
                            Picker("Country", selection: $country) {
                                ForEach(countries) { c in
                                    Text("\(c.flag) \(c.name) (+\(c.callingCode))").tag(c)
                                }
                            }
                        } label: {
                            HStack {
                                Text("\(country.flag) \(country.name)").foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .accessibilityLabel("Country, \(country.name)")
                    }
                    divider
                }
                row("phone") {
                    Text("\(countries.count > 1 ? "" : country.flag + " ")+\(country.callingCode)")
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                    TextField("Phone number", text: $number)
                        .focused($focused, equals: .number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .tint(.white)
                }
                .contentShape(.rect)
                .onTapGesture { focused = .number }
                divider
                discoverableRow
            }

            error

            primaryButton("Send code", enabled: typedNumber != nil) { sendCode() }

            footnote
        }
        .onAppear { if context == .settings { focused = .number } }
    }

    private var enterCodeStep: some View {
        VStack(spacing: 16) {
            header("Check your messages", "Enter the code we texted to \(PhoneNumbers.display(pendingNumber ?? "")).")

            card {
                row("number") {
                    TextField("Code", text: $code)
                        .focused($focused, equals: .code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .foregroundStyle(.white)
                        .tint(.white)
                }
                .contentShape(.rect)
                .onTapGesture { focused = .code }
            }
            .onAppear { focused = .code }

            error

            primaryButton("Continue", enabled: codeDigits.count == Self.codeLength) { verify() }

            textButton("Resend code") { sendCode(resending: true) }
            if let resendNote {
                Text(resendNote)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var addedStep: some View {
        VStack(spacing: 16) {
            header(context == .onboarding ? "You're all set" : "Phone number",
                   "Friends with your number can find you.")

            card {
                row("phone") {
                    Text(savedNumber.map(PhoneNumbers.display) ?? "Added")
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                divider
                discoverableRow
            }

            error

            primaryButton(context == .onboarding ? "Continue" : "Done", action: onDone)

            if context == .settings {
                HStack(spacing: 24) {
                    textButton("Change number") {
                        number = ""
                        errorMessage = nil
                        step = .enterNumber
                    }
                    textButton("Remove", color: .red.opacity(0.9)) { confirmingRemove = true }
                }
                .frame(minHeight: 44)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            let status = try await service.phoneStatus()
            discoverable = status.hasPhone ? status.discoverable : true
            if let prefixes = status.allowedPrefixes {
                let allowed = PhoneNumbers.countries.filter { c in
                    prefixes.contains { ("+" + c.callingCode).hasPrefix($0) }
                }
                if !allowed.isEmpty {
                    countries = allowed
                    if !allowed.contains(country) { country = allowed[0] }
                }
            }
            step = !status.available && !status.hasPhone ? .unavailable : (status.hasPhone ? .added : .enterNumber)
        } catch {
            errorMessage = FriendlyError.message(for: error)
            step = .enterNumber
        }
    }

    private func sendCode(resending: Bool = false) {
        guard let phone = resending ? pendingNumber : typedNumber else { return }
        focused = nil
        resendNote = nil
        run {
            try await service.startPhoneVerification(phone)
            pendingNumber = phone
            code = ""
            step = .enterCode
            focused = .code
            if resending { resendNote = "Sent. It can take a minute to arrive." }
        }
    }

    private func verify() {
        guard let phone = pendingNumber, codeDigits.count == Self.codeLength, !working else { return }
        run(onError: { code = "" }) {
            try await service.verifyPhone(phone, code: codeDigits, discoverable: discoverable)
            focused = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            step = .added
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
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}
