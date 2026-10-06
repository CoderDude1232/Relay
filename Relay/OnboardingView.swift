//
//  OnboardingView.swift
//  Relay
//

import AuthenticationServices
import CryptoKit
import SwiftUI

private struct GoogleGLogo: View {
    var body: some View {
        Image("google-logo")
            .resizable()
            .scaledToFit()
    }
}

// MARK: - Root

struct OnboardingView: View {

    @Environment(AppModel.self) private var model

    enum Step { case welcome, auth, setup, recovery }

    @State private var step: Step = .welcome
    @State private var supabaseSession: SupabaseSession?
    @State private var supabasePassword = ""  // threaded from AuthView for account recovery setup
    @State private var displayName = ""
    @State private var username = ""
    @State private var registrationError: String?
    @State private var showingLinkScanner = false
    @State private var isAutoRestoring = false

    var body: some View {
        ZStack {
            BackgroundGradient()
            if isAutoRestoring {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            } else {
            switch step {
            case .welcome:
                WelcomeView(
                    onSignUp: {
                        withAnimation(.spring(duration: 0.5)) { step = .auth }
                    },
                    onSignIn: {
                        withAnimation(.spring(duration: 0.5)) { step = .recovery }
                    },
                    onOAuthSession: { session in
                        handleOAuth(session: session)
                    },
                    onLinkDevice: {
                        showingLinkScanner = true
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            case .auth:
                AuthView(onComplete: { session, password in
                    supabaseSession = session
                    supabasePassword = password
                    withAnimation(.spring(duration: 0.5)) { step = .setup }
                }, onBack: {
                    withAnimation(.spring(duration: 0.5)) { step = .welcome }
                })
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            case .setup:
                SetupView(
                    displayName: $displayName,
                    username: $username,
                    checkAvailability: { u in await model.checkUsernameAvailable(u) },
                    onComplete: {
                        guard let session = supabaseSession else { return }
                        try await finish(session: session, password: supabasePassword)
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            case .recovery:
                RecoveryView(onComplete: {
                    // recoverAccount sets phase = .ready; onboarding auto-dismisses.
                }, onBack: {
                    withAnimation(.spring(duration: 0.5)) { step = .welcome }
                })
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
            } // end else isAutoRestoring
        }
        .animation(.spring(duration: 0.5), value: step)
        .task {
            // If a Supabase session is already stored (e.g. after a relay-only
            // sign-out due to server reset), try to re-use it without prompting
            // for OAuth again. If the session has expired, the refresh will fail
            // and we fall back to the normal onboarding flow.
            let stored = await SupabaseAuth.shared.session
            guard let stored else { return }
            // Existing relay credentials → boot already handled this; skip.
            guard !model.hasExistingRelayAccount(forUserId: stored.userId) else { return }
            isAutoRestoring = true
            do {
                // Try to refresh in case the access token expired.
                let session: SupabaseSession
                do {
                    session = try await SupabaseAuth.shared.refresh()
                } catch {
                    // Refresh failed (e.g. revoked token) — use stored session as-is.
                    // If the access token is still valid the registration will succeed;
                    // if not, the error surfaces as a registrationError below.
                    session = stored
                }
                supabaseSession = session
                try await finish(session: session, password: "")
            } catch is AppModel.NeedsUsernameError {
                // Session is valid but there's no relay account yet — send the
                // user to pick a username.
                isAutoRestoring = false
                withAnimation(.spring(duration: 0.5)) { step = .setup }
            } catch {
                registrationError = error.localizedDescription
                isAutoRestoring = false
            }
        }
        .alert("Sign In Failed", isPresented: Binding(
            get: { registrationError != nil },
            set: { if !$0 { registrationError = nil } }
        )) {
            Button("OK", role: .cancel) { registrationError = nil }
        } message: {
            Text(registrationError ?? "")
        }
        .sheet(isPresented: $showingLinkScanner) {
            LinkNewDeviceView()
                .environment(model)
        }
    }

    private func handleOAuth(session: SupabaseSession) {
        supabaseSession = session
        Task {
            do {
                // Try to sign straight in. Returning users — even on a brand-new
                // device with no local credentials — are recovered by the relay
                // via their verified Supabase token, so no username is needed.
                try await finish(session: session, password: "")
            } catch is AppModel.NeedsUsernameError {
                // Brand-new user — prefill a display name and prompt for a username.
                if displayName.isEmpty {
                    let prefix = session.email.components(separatedBy: "@").first ?? ""
                    if !prefix.isEmpty {
                        displayName = prefix.split(separator: ".").map { $0.capitalized }.joined(separator: " ")
                    }
                }
                withAnimation(.spring(duration: 0.5)) { step = .setup }
            } catch {
                registrationError = error.localizedDescription
            }
        }
    }

    private func finish(session: SupabaseSession, password: String = "") async throws {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let handle = username.trimmingCharacters(in: .whitespaces)
        try await model.registerWithSupabase(
            serverURL: RelayConfig.serverURL,
            accessToken: session.accessToken,
            email: session.email,
            supabaseUserId: session.userId,
            username: handle.isEmpty ? nil : handle,
            displayName: name,
            accountPassword: password.isEmpty ? nil : password
        )
    }
}

// MARK: - Animated background

private struct BackgroundGradient: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            // Near-black base with a soft magenta glow that matches the logo /
            // accent, gently breathing.
            Color(red: 0.03, green: 0.03, blue: 0.05)

            RadialGradient(
                colors: [Color(red: 0.965, green: 0.231, blue: 1.0).opacity(phase ? 0.30 : 0.18), .clear],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color(red: 0.776, green: 0.067, blue: 0.839).opacity(phase ? 0.18 : 0.10), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}

// MARK: - Welcome

private struct WelcomeView: View {
    let onSignUp: () -> Void
    let onSignIn: () -> Void
    let onOAuthSession: (SupabaseSession) -> Void
    let onLinkDevice: () -> Void

    @State private var oauthLoading = false
    @State private var oauthError: String?
    @State private var pendingCodeVerifier: String?
    @State private var googleWebSession: ASWebAuthenticationSession?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Brand
            VStack(spacing: 14) {
                Image("RelayLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250)
                Text("Private messaging,\nend-to-end encrypted.")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Spacer()

            // Actions
            VStack(spacing: 10) {
                if oauthLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                } else {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.email, .fullName]
                    } onCompletion: { result in
                        handleAppleResult(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))

                    Button(action: startGoogleSignIn) {
                        HStack(spacing: 10) {
                            GoogleGLogo().frame(width: 20, height: 20)
                            Text("Continue with Google")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color(red: 0.2, green: 0.2, blue: 0.2))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white, in: .rect(cornerRadius: 14, style: .continuous))
                    }

                    Button(action: onSignUp) {
                        Text("Create account with email")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.white.opacity(0.13), in: .rect(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                    }
                }

                if let oauthError {
                    InlineErrorBanner(oauthError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Sign-in row — visible, clearly labeled for returning users
                Button(action: onSignIn) {
                    HStack {
                        Text("Already have an account?")
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Sign in")
                            .foregroundStyle(.white.opacity(0.85))
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }

                Button(action: onLinkDevice) {
                    Text("Link existing device")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 28)
            .padding(.bottom, 52)
        }
    }

    // MARK: Apple

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else {
                oauthError = "Apple Sign In returned an unexpected credential."
                return
            }
            oauthLoading = true
            oauthError = nil
            Task {
                do {
                    let session = try await SupabaseAuth.shared.signInWithApple(identityToken: token)
                    onOAuthSession(session)
                } catch {
                    oauthError = error.localizedDescription
                }
                oauthLoading = false
            }
        case .failure(let error):
            let asErr = error as? ASAuthorizationError
            if asErr?.code != .canceled {
                oauthError = error.localizedDescription
            }
        }
    }

    // MARK: Google (PKCE via ASWebAuthenticationSession)

    private func startGoogleSignIn() {
        let verifier = makeCodeVerifier()
        let challenge = codeChallenge(from: verifier)
        pendingCodeVerifier = verifier

        let redirect = "app.relaymsg://auth-callback"
        guard let encodedRedirect = redirect.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let authURL = URL(string: "\(SupabaseConfig.projectURL)/auth/v1/authorize?provider=google&redirect_to=\(encodedRedirect)&code_challenge=\(challenge)&code_challenge_method=s256")
        else { return }

        oauthLoading = true
        oauthError = nil

        let ws = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "app.relaymsg"
        ) { callbackURL, error in
            googleWebSession = nil
            if let error {
                oauthLoading = false
                let asErr = error as? ASWebAuthenticationSessionError
                if asErr?.code != .canceledLogin {
                    oauthError = error.localizedDescription
                }
                return
            }
            guard let callbackURL else {
                oauthLoading = false
                return
            }
            Task { await handleGoogleCallback(callbackURL) }
        }
        ws.prefersEphemeralWebBrowserSession = false
        ws.presentationContextProvider = OAuthWindowContext.shared
        ws.start()
        googleWebSession = ws
    }

    private func handleGoogleCallback(_ url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier = pendingCodeVerifier
        else {
            oauthLoading = false
            oauthError = "Invalid OAuth callback — missing authorization code."
            return
        }
        pendingCodeVerifier = nil
        do {
            let session = try await SupabaseAuth.shared.exchangeOAuthCode(code, verifier: verifier)
            onOAuthSession(session)
        } catch {
            oauthError = error.localizedDescription
        }
        oauthLoading = false
    }

    // MARK: PKCE helpers

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func codeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - OAuth presentation context

@MainActor
private final class OAuthWindowContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthWindowContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap { $0.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

// MARK: - Auth screen

private struct AuthView: View {
    let onComplete: (SupabaseSession, String) async throws -> Void
    let onBack: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    enum Field: Hashable { case email, password, confirm }

    private var canSubmit: Bool {
        guard !isLoading, !email.isEmpty, password.count >= 8 else { return false }
        return password == confirmPassword
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                VStack(spacing: 6) {
                    Text("Create account")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Private messaging starts here.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 32)
                .padding(.bottom, 36)

                VStack(spacing: 0) {
                    AuthField(icon: "envelope", placeholder: "Email address",
                              text: $email, focused: $focused, field: .email,
                              contentType: .emailAddress, keyboard: .emailAddress)
                    Divider().background(.white.opacity(0.12))
                    AuthField(icon: "lock", placeholder: "Password (min 8 chars)",
                              text: $password, focused: $focused, field: .password,
                              contentType: .newPassword, secure: true)
                    Divider().background(.white.opacity(0.12))
                    AuthField(icon: "lock.fill", placeholder: "Confirm password",
                              text: $confirmPassword, focused: $focused, field: .confirm,
                              contentType: .newPassword, secure: true)
                }
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 24)

                if !confirmPassword.isEmpty && password != confirmPassword {
                    Label("Passwords don't match", systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                }

                if let errorMessage {
                    InlineErrorBanner(errorMessage)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                }

                Button(action: submit) {
                    ZStack {
                        if isLoading {
                            ProgressView().tint(Color(red: 0.06, green: 0.02, blue: 0.22))
                        } else {
                            Text("Create account")
                                .font(.headline)
                                .foregroundStyle(Color(red: 0.06, green: 0.02, blue: 0.22))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        canSubmit ? Color.white : Color.white.opacity(0.3),
                        in: .rect(cornerRadius: 16, style: .continuous)
                    )
                }
                .disabled(!canSubmit)
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Text("By continuing you agree to our Terms & Privacy Policy.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 16)

                Spacer().frame(height: 40)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        errorMessage = nil
        isLoading = true
        focused = nil
        Task {
            do {
                let session = try await SupabaseAuth.shared.signUp(email: email, password: password)
                try await onComplete(session, password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Recovery screen (sign in by email + account password)

private struct RecoveryView: View {
    let onComplete: () -> Void
    let onBack: () -> Void

    @Environment(AppModel.self) private var model

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focused: RecoveryField?

    enum RecoveryField: Hashable { case email, password }

    private var canSubmit: Bool {
        !isLoading && !email.isEmpty && password.count >= 6
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                VStack(spacing: 6) {
                    Text("Sign in")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Recover access with your email and password.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 32)
                .padding(.bottom, 36)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "envelope")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24)
                        TextField("Email address", text: $email)
                            .focused($focused, equals: .email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)

                    Divider().background(.white.opacity(0.12))

                    HStack(spacing: 12) {
                        Image(systemName: "lock")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24)
                        SecureField("Password", text: $password)
                            .focused($focused, equals: .password)
                            .textContentType(.password)
                            .foregroundStyle(.white)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 24)

                if let errorMessage {
                    InlineErrorBanner(errorMessage)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                }

                Button(action: submit) {
                    ZStack {
                        if isLoading {
                            ProgressView().tint(Color(red: 0.06, green: 0.02, blue: 0.22))
                        } else {
                            Text("Sign in")
                                .font(.headline)
                                .foregroundStyle(Color(red: 0.06, green: 0.02, blue: 0.22))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        canSubmit ? Color.white : Color.white.opacity(0.3),
                        in: .rect(cornerRadius: 16, style: .continuous)
                    )
                }
                .disabled(!canSubmit)
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Text("Only works if you created your account with email sign-up.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 16)

                Spacer().frame(height: 40)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        errorMessage = nil
        isLoading = true
        focused = nil
        Task {
            do {
                try await model.recoverAccount(
                    serverURL: RelayConfig.serverURL,
                    email: email.lowercased().trimmingCharacters(in: .whitespaces),
                    accountPassword: password
                )
                onComplete()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct AuthField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<AuthView.Field?>.Binding
    let field: AuthView.Field
    var contentType: UITextContentType = .emailAddress
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never
    var secure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)

            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(capitalization)
                        .autocorrectionDisabled()
                }
            }
            .textContentType(contentType)
            .focused(focused, equals: field)
            .foregroundStyle(.white)
            .tint(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .contentShape(.rect)
        .onTapGesture { focused.wrappedValue = field }
    }
}

// MARK: - Setup (display name + username, sign-up only)

private struct SetupView: View {
    @Binding var displayName: String
    @Binding var username: String
    let checkAvailability: (String) async -> Bool
    let onComplete: () async throws -> Void

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var usernameStatus: UsernameStatus = .idle
    @State private var checkTask: Task<Void, Never>?
    @FocusState private var focused: SetupField?

    enum SetupField: Hashable { case displayName, username }

    enum UsernameStatus: Equatable {
        case idle, checking, available, taken, invalid(String)
    }

    private var canContinue: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty, !isLoading else { return false }
        if case .available = usernameStatus { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 8)
                Text("Set up your profile")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Seen by the people you message.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.bottom, 36)

            VStack(spacing: 0) {
                // Display name row
                HStack(spacing: 12) {
                    Image(systemName: "person")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 24)
                    TextField("Display name", text: $displayName)
                        .focused($focused, equals: .displayName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                        .tint(.white)
                        .submitLabel(.next)
                        .onSubmit { focused = .username }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                Divider().background(.white.opacity(0.12))

                // Username row
                HStack(spacing: 12) {
                    Text("@")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 24)
                    TextField("username", text: $username)
                        .focused($focused, equals: .username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                        .tint(.white)
                        .submitLabel(.done)
                        .onSubmit { focused = nil }
                        .onChange(of: username) { _, new in scheduleCheck(new) }
                    usernameStatusIcon
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 28)
            .onAppear { focused = .displayName }

            usernameStatusLabel
                .padding(.horizontal, 32)
                .padding(.top, 8)

            if let errorMessage {
                InlineErrorBanner(errorMessage)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }

            Spacer()

            Button {
                focused = nil
                isLoading = true
                errorMessage = nil
                Task {
                    do {
                        try await onComplete()
                    } catch {
                        errorMessage = error.localizedDescription
                        isLoading = false
                    }
                }
            } label: {
                ZStack {
                    if isLoading {
                        ProgressView().tint(Color(red: 0.06, green: 0.02, blue: 0.22))
                    } else {
                        Text("Start messaging")
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.06, green: 0.02, blue: 0.22))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    canContinue ? Color.white : Color.white.opacity(0.3),
                    in: .rect(cornerRadius: 16, style: .continuous)
                )
            }
            .disabled(!canContinue)
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var usernameStatusIcon: some View {
        switch usernameStatus {
        case .idle:           EmptyView()
        case .checking:       ProgressView().scaleEffect(0.75).tint(.white.opacity(0.6))
        case .available:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .taken, .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.8))
        }
    }

    @ViewBuilder
    private var usernameStatusLabel: some View {
        switch usernameStatus {
        case .idle:
            Text("Letters, digits and underscores. 3–20 characters.")
                .font(.caption).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
        case .checking:
            Text("Checking availability…")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
        case .available:
            Text("@\(username) is available")
                .font(.caption).foregroundStyle(.green.opacity(0.9))
        case .taken:
            Text("@\(username) is already taken")
                .font(.caption).foregroundStyle(.red.opacity(0.85))
        case .invalid(let reason):
            Text(reason)
                .font(.caption).foregroundStyle(.orange.opacity(0.9)).multilineTextAlignment(.center)
        }
    }

    private func scheduleCheck(_ raw: String) {
        // Auto-lowercase
        let lower = raw.lowercased()
        if lower != raw { username = lower; return }

        checkTask?.cancel()
        guard !lower.isEmpty else { usernameStatus = .idle; return }

        if let reason = validationError(lower) { usernameStatus = .invalid(reason); return }

        usernameStatus = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let available = await checkAvailability(lower)
            guard !Task.isCancelled else { return }
            usernameStatus = available ? .available : .taken
        }
    }

    private func validationError(_ u: String) -> String? {
        if u.count < 3  { return "Too short — minimum 3 characters." }
        if u.count > 20 { return "Too long — maximum 20 characters." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if u.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Only letters, digits and underscores."
        }
        return nil
    }
}
