//
//  PhoneNumberView.swift
//  Relay
//
//  Profile → Account → Phone Number. Optional: a number lets people who
//  already have it find you. It's verified once by text, never shown to
//  anyone, and isn't a way to sign in.
//

import RelayKit
import SwiftUI

struct PhoneNumberView: View {
    let service: MessagingService

    private enum Step { case loading, unavailable, enterNumber, enterCode, added }

    @State private var step: Step = .loading
    @State private var country = PhoneNumbers.defaultCountry
    @State private var number = ""
    @State private var code = ""
    @State private var discoverable = true
    @State private var pendingNumber: String?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var confirmingRemove = false
    @FocusState private var focused: Bool

    private var savedNumber: String? { UserDefaults.standard.string(forKey: MessagingService.phoneNumberKey) }
    private var typedNumber: String? { PhoneNumbers.e164(number, country: country) }

    var body: some View {
        Form {
            switch step {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .unavailable:
                Section {
                    Text("Phone numbers aren't available yet.")
                        .foregroundStyle(.secondary)
                }
            case .enterNumber:
                enterNumberSections
            case .enterCode:
                enterCodeSections
            case .added:
                addedSections
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Phone Number")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("Remove your phone number?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { run { try await service.removePhone(); step = .enterNumber } }
        } message: {
            Text("People who have your number won't be able to find you on Relay anymore. Your chats aren't affected.")
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var enterNumberSections: some View {
        Section {
            Picker("Country", selection: $country) {
                ForEach(PhoneNumbers.countries) { c in
                    Text("\(c.flag) \(c.name) (+\(c.callingCode))").tag(c)
                }
            }
            HStack {
                Text("+\(country.callingCode)").foregroundStyle(.secondary)
                TextField("Phone number", text: $number)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focused)
            }
            Toggle("Let people who have my number find me", isOn: $discoverable)
        } footer: {
            Text("Optional. Your number is never shown to anyone and isn't used to sign in. Relay stores only a scrambled form of it that can't be turned back into your number.")
        }
        Section {
            Button {
                guard let phone = typedNumber else { return }
                run {
                    try await service.startPhoneVerification(phone)
                    pendingNumber = phone
                    code = ""
                    step = .enterCode
                }
            } label: {
                HStack {
                    Text("Send Code")
                    Spacer()
                    if working { ProgressView() }
                }
            }
            .disabled(typedNumber == nil || working)
        } footer: {
            Text("We'll text a 6-digit code. Standard message rates may apply.")
        }
    }

    @ViewBuilder
    private var enterCodeSections: some View {
        Section {
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .onAppear { focused = true }
        } header: {
            Text("Code sent to \(PhoneNumbers.display(pendingNumber ?? ""))")
        }
        Section {
            Button {
                guard let phone = pendingNumber else { return }
                run {
                    try await service.verifyPhone(phone, code: code, discoverable: discoverable)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    step = .added
                }
            } label: {
                HStack {
                    Text("Verify")
                    Spacer()
                    if working { ProgressView() }
                }
            }
            .disabled(code.filter(\.isNumber).count < 4 || working)
            Button("Use a Different Number") {
                errorMessage = nil
                step = .enterNumber
            }
        }
    }

    @ViewBuilder
    private var addedSections: some View {
        Section {
            LabeledContent("Number", value: savedNumber.map(PhoneNumbers.display) ?? "Added")
            Toggle("Let people who have my number find me", isOn: Binding(
                get: { discoverable },
                set: { on in
                    let previous = discoverable
                    discoverable = on
                    run(onError: { discoverable = previous }) { try await service.setPhoneDiscoverable(on) }
                }
            ))
        } footer: {
            Text("Your number is never shown to anyone. When this is off, nobody can find you by it.")
        }
        Section {
            Button("Change Number") {
                number = ""
                errorMessage = nil
                step = .enterNumber
            }
            Button("Remove Phone Number", role: .destructive) { confirmingRemove = true }
        }
    }

    // MARK: Helpers

    private func load() async {
        do {
            let status = try await service.phoneStatus()
            discoverable = status.hasPhone ? status.discoverable : true
            step = !status.available && !status.hasPhone ? .unavailable : (status.hasPhone ? .added : .enterNumber)
        } catch {
            errorMessage = FriendlyError.message(for: error)
            step = .enterNumber
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
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}
