//
//  PhoneNumberView.swift
//  Relay
//
//  The optional phone number, in the onboarding style: offered once right
//  after a new account, and opened from Profile → Account → Phone Number.
//  A number lets people who already have it find you. It's verified once by
//  text, never shown to anyone, and isn't a way to sign in.
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
    @State private var confirmingRemove = false
    @State private var resendAvailableAt = Date.distantPast
    @FocusState private var focused: Field?

    private enum Field: Hashable { case number, code }

    private static let codeLength = 6
    private static let ink = Color(red: 0.06, green: 0.02, blue: 0.22)
    private static let magenta = Color(red: 0.965, green: 0.231, blue: 1.0)

    private var savedNumber: String? { UserDefaults.standard.string(forKey: MessagingService.phoneNumberKey) }
    private var typedNumber: String? { PhoneNumbers.e164(number, country: country) }
    private var codeDigits: String { String(code.filter(\.isNumber).prefix(Self.codeLength)) }

    var body: some View {
        ZStack {
            BackgroundGradient()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    Group {
                        switch step {
                        case .loading:
                            ProgressView().tint(.white).padding(.top, 160)
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
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .animation(.spring(duration: 0.4), value: step)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .task { await load() }
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

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            if step == .enterCode {
                circleButton("chevron.left", label: "Back") {
                    errorMessage = nil
                    step = .enterNumber
                }
            } else if context == .settings {
                circleButton("xmark", label: "Close", action: onDone)
            }
            Spacer()
            if context == .onboarding, step != .added {
                Button("Skip", action: onDone)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(height: 40)
                    .padding(.horizontal, 6)
                    .disabled(working)
            }
        }
        .frame(height: 40)
        .padding(.horizontal, 24)
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

    private func header(_ systemName: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 36)
    }

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
            .background(enabled ? Color.white : Color.white.opacity(0.3),
                        in: .rect(cornerRadius: 16, style: .continuous))
        }
        .disabled(!enabled || working)
        .padding(.horizontal, 28)
    }

    private func secondaryButton(_ title: String, color: Color = .white.opacity(0.75), action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.vertical, 8)
            .disabled(working)
    }

    private var discoverableCard: some View {
        Toggle(isOn: Binding(
            get: { discoverable },
            set: { on in
                guard step == .added else { discoverable = on; return }
                let previous = discoverable
                discoverable = on
                run(onError: { discoverable = previous }) { try await service.setPhoneDiscoverable(on) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Let people find me by number")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text("Only people who already have it.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .tint(Self.magenta)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 28)
    }

    private var privacyNote: some View {
        Label {
            Text("Never shown to anyone and not used to sign in. Relay keeps only a scrambled form that can't be turned back into your number.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var error: some View {
        if let errorMessage {
            InlineErrorBanner(errorMessage)
                .padding(.horizontal, 28)
                .padding(.top, 12)
        }
    }

    // MARK: Steps

    private var unavailableStep: some View {
        VStack(spacing: 0) {
            header("phone.badge.waveform", "Coming soon",
                   "Adding a phone number isn't available yet. You can add one later in Settings → Account.")
            primaryButton(context == .onboarding ? "Continue" : "Done", action: onDone)
        }
    }

    private var enterNumberStep: some View {
        VStack(spacing: 0) {
            header("phone.circle",
                   savedNumber == nil ? "Add your phone number" : "Change your number",
                   "Optional. Friends who have your number in their contacts can find you on Relay.")

            VStack(spacing: 0) {
                if countries.count > 1 {
                    Menu {
                        Picker("Country", selection: $country) {
                            ForEach(countries) { c in
                                Text("\(c.flag) \(c.name) (+\(c.callingCode))").tag(c)
                            }
                        }
                    } label: {
                        countryRow(showsChevron: true)
                    }
                    .accessibilityLabel("Country, \(country.name)")
                } else {
                    countryRow(showsChevron: false)
                }

                Divider().background(.white.opacity(0.12))

                HStack(spacing: 12) {
                    Text("+\(country.callingCode)")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(minWidth: 24, alignment: .leading)
                    TextField("Phone number", text: $number)
                        .focused($focused, equals: .number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.white)
                        .tint(.white)
                    if typedNumber != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.25), value: typedNumber != nil)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 28)

            discoverableCard.padding(.top, 12)
            privacyNote.padding(.top, 14)
            error

            primaryButton("Send Code", enabled: typedNumber != nil) { sendCode() }
                .padding(.top, 28)
            Text("We'll text you a 6-digit code. Standard message rates may apply.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 12)
            if context == .onboarding {
                secondaryButton("Not now", action: onDone).padding(.top, 8)
            }
            Spacer(minLength: 40)
        }
        .onAppear { if context == .settings || savedNumber != nil { focused = .number } }
    }

    private var enterCodeStep: some View {
        VStack(spacing: 0) {
            header("message.badge", "Enter the code",
                   "Sent to \(PhoneNumbers.display(pendingNumber ?? ""))")

            ZStack {
                // The real field sits under the boxes so paste and SMS
                // autofill work; tapping anywhere focuses it.
                TextField("", text: $code)
                    .focused($focused, equals: .code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .accessibilityLabel("Verification code")
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(Self.codeLength))
                        if digits != new { code = digits; return }
                        if digits.count == Self.codeLength { verify() }
                    }
                HStack(spacing: 8) {
                    ForEach(0..<Self.codeLength, id: \.self) { i in
                        codeBox(at: i)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(.rect)
            .onTapGesture { focused = .code }
            .padding(.horizontal, 28)
            .onAppear { focused = .code }

            error

            primaryButton("Verify", enabled: codeDigits.count == Self.codeLength) { verify() }
                .padding(.top, 28)

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let wait = Int(resendAvailableAt.timeIntervalSince(timeline.date).rounded(.up))
                secondaryButton(wait > 0 ? "Resend code in \(wait)s" : "Resend code") { sendCode() }
                    .disabled(wait > 0 || working)
                    .opacity(wait > 0 ? 0.5 : 1)
            }
            .padding(.top, 12)
            secondaryButton("Use a different number") {
                errorMessage = nil
                step = .enterNumber
            }
            Spacer(minLength: 40)
        }
    }

    private func countryRow(showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            Text(country.flag).font(.title3).frame(width: 24)
            Text(country.name).foregroundStyle(.white)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .contentShape(.rect)
    }

    private func codeBox(at index: Int) -> some View {
        let digits = Array(codeDigits)
        let isCurrent = index == digits.count && focused == .code
        return Text(index < digits.count ? String(digits[index]) : "")
            .font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(maxWidth: 52)
            .frame(height: 60)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isCurrent ? Color.white.opacity(0.8) : Color.white.opacity(0.12),
                                  lineWidth: isCurrent ? 1.5 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: isCurrent)
    }

    private var addedStep: some View {
        VStack(spacing: 0) {
            header("checkmark.circle", context == .onboarding ? "You're all set" : "Phone number",
                   savedNumber.map(PhoneNumbers.display) ?? "Your number is added.")

            discoverableCard
            privacyNote.padding(.top, 14)
            error

            primaryButton(context == .onboarding ? "Continue" : "Done", action: onDone)
                .padding(.top, 28)
            if context == .settings {
                secondaryButton("Change number") {
                    number = ""
                    errorMessage = nil
                    step = .enterNumber
                }
                .padding(.top, 8)
                secondaryButton("Remove phone number", color: .red.opacity(0.9)) { confirmingRemove = true }
            }
            Spacer(minLength: 40)
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

    private func sendCode() {
        guard let phone = step == .enterCode ? pendingNumber : typedNumber else { return }
        focused = nil
        run {
            try await service.startPhoneVerification(phone)
            pendingNumber = phone
            code = ""
            resendAvailableAt = .now.addingTimeInterval(30)
            step = .enterCode
            focused = .code
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
