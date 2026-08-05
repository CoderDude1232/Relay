//
//  OnboardingView.swift
//  Relay
//
//  First-launch registration: server, username, password.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var serverURL = "https://192.168.0.134:8089"
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        URL(string: serverURL) != nil && !username.isEmpty
            && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 8 && !isRegistering
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Relay")
                .font(.largeTitle.bold())
            Text("End-to-end encrypted messaging")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Server", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Display name", text: $displayName)
                    .textContentType(.name)
                SecureField("Password (min 8 characters)", text: $password)
                    .textContentType(.newPassword)
            }
            .textFieldStyle(.roundedBorder)
            .padding(20)
            .glassEffect(in: .rect(cornerRadius: 20))

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                register()
            } label: {
                if isRegistering {
                    ProgressView()
                } else {
                    Text("Create Account")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(!canSubmit)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func register() {
        guard let url = URL(string: serverURL) else { return }
        isRegistering = true
        errorMessage = nil
        Task {
            do {
                try await model.register(serverURL: url, username: username, displayName: displayName, password: password)
            } catch {
                errorMessage = "Registration failed: \(error.localizedDescription)"
            }
            isRegistering = false
        }
    }
}
