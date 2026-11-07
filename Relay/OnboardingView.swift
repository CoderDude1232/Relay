//
//  OnboardingView.swift
//  Relay
//

import AuthenticationServices
import CryptoKit
import RelayCore
import RelayKit
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

    enum Step { case welcome, signIn, emailCode, phone, phoneSetup, setup, passkeyIntro, passkeySetup, twoStep }

    @State private var step: Step = .welcome
    @State private var signInSession: SignInSession?
    /// Accounts on a relay from before two-step verification answer a
    /// registration lock with a plain account-password prompt.
    @State private var showingLockPrompt = false
    @State private var lockPassword = ""
    @State private var lockPasswordIncorrect = false
    @State private var twoStep: AppModel.TwoStepNeededError?
    @State private var phoneSignup: (phone: String, ticket: String)?
    @State private var displayName = ""
    @State private var username = ""
    @State private var registrationError: String?
    @State private var showingLinkScanner = false
    @State private var isAutoRestoring = false

    private static let forward = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )
    private static let toForm = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .opacity
    )

    private func go(_ next: Step) {
        withAnimation(.spring(duration: 0.5)) { step = next }
    }

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
                    onPhone: { go(.phone) },
                    onEmail: { go(.emailCode) },
                    onUsernameOnly: { go(.passkeyIntro) },
                    onSignIn: { go(.signIn) },
                    onOAuthSession: { session, name in
                        handleOAuth(session: session, suggestedName: name)
                    },
                    onLinkDevice: {
                        showingLinkScanner = true
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            case .signIn:
                SignInOptionsView(onPhone: { go(.phone) }, onEmail: { go(.emailCode) }, onBack: { go(.welcome) })
                    .transition(Self.forward)
            case .phone:
                PhoneSignInView(onNewAccount: { phone, ticket in
                    phoneSignup = (phone, ticket)
                    go(.phoneSetup)
                }, onTwoStep: { needed in
                    twoStep = needed
                    go(.twoStep)
                }, onBack: { go(.welcome) })
                .transition(Self.forward)
            case .phoneSetup:
                SetupView(
                    displayName: $displayName,
                    username: $username,
                    checkAvailability: { u in await model.checkUsername(u) },
                    onComplete: {
                        guard let phoneSignup else { return }
                        try await model.signUpWithPhone(
                            phoneSignup.phone, signupTicket: phoneSignup.ticket,
                            username: username.trimmingCharacters(in: .whitespaces),
                            displayName: displayName.trimmingCharacters(in: .whitespaces),
                            discoverable: false
                        )
                    },
                    onBack: {
                        phoneSignup = nil
                        go(.phone)
                    }
                )
                .transition(Self.toForm)
            case .passkeyIntro:
                PasskeySignupIntroView(onContinue: { go(.passkeySetup) }, onBack: { go(.welcome) })
                    .transition(Self.forward)
            case .passkeySetup:
                SetupView(
                    displayName: $displayName,
                    username: $username,
                    checkAvailability: { u in await model.checkUsername(u) },
                    onComplete: {
                        try await model.signUpWithPasskey(username: username, displayName: displayName)
                    },
                    onBack: { go(.passkeyIntro) }
                )
                .transition(Self.toForm)
            case .emailCode:
                EmailCodeView(onSession: { session in
                    handleOAuth(session: session)
                }, onBack: { go(.welcome) })
                .transition(Self.forward)
            case .setup:
                SetupView(
                    displayName: $displayName,
                    username: $username,
                    checkAvailability: { u in await model.checkUsername(u) },
                    onComplete: {
                        guard let session = signInSession else { return }
                        try await finish(session: session)
                    },
                    onBack: {
                        // Forget the half-finished sign-up so the user can pick another sign-in
                        // method.
                        signInSession = nil
                        go(.welcome)
                    }
                )
                .transition(Self.toForm)
            case .twoStep:
                if let twoStep {
                    TwoStepView(needed: twoStep, onRestart: {
                        self.twoStep = nil
                        signInSession = nil
                        go(.welcome)
                    })
                    .transition(Self.forward)
                }
            }
            } // end else isAutoRestoring
        }
        .animation(.spring(duration: 0.5), value: step)
        // White text over .ultraThinMaterial on near-black; force dark so the
        // material stays dark in Light Mode.
        .preferredColorScheme(.dark)
        .task {
            // Reuse this run's sign-in (e.g. after a relay-only sign-out) instead of
            // asking again. If its ticket has expired the relay says so and the
            // normal flow takes over.
            let stored = await SignInAuth.shared.session
            guard let stored else { return }
            // Existing relay credentials: boot already handled this.
            guard !model.hasExistingRelayAccount(forUserId: stored.userId) else { return }
            isAutoRestoring = true
            do {
                let session = stored
                signInSession = session
                try await finish(session: session)
            } catch is AppModel.NeedsUsernameError {
                // Valid session but no relay account yet: pick a username.
                isAutoRestoring = false
                go(.setup)
            } catch let needed as AppModel.TwoStepNeededError {
                isAutoRestoring = false
                twoStep = needed
                go(.twoStep)
            } catch {
                registrationError = FriendlyError.message(for: error)
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
        .alert("Account Password", isPresented: $showingLockPrompt) {
            SecureField("Account password", text: $lockPassword)
            Button("Sign In") {
                if let session = signInSession {
                    handleOAuth(session: session, accountPassword: lockPassword)
                }
            }
            Button("Cancel", role: .cancel) { lockPassword = "" }
        } message: {
            Text(lockPasswordIncorrect
                 ? "That password is incorrect. Try again."
                 : "This account is protected by an account password. Signing in here will sign out your other devices.")
        }
        .sheet(isPresented: $showingLinkScanner) {
            LinkNewDeviceView()
                .environment(model)
        }
    }

    private func handleOAuth(session: SignInSession, accountPassword: String = "", suggestedName: String? = nil) {
        signInSession = session
        Task {
            do {
                // Returning users, even on a new device with no local credentials, are
                // recovered by the relay via their verified sign-in, so no
                // username is needed.
                try await finish(session: session, password: accountPassword)
            } catch let needed as AppModel.TwoStepNeededError {
                twoStep = needed
                go(.twoStep)
            } catch let lock as AppModel.AccountPasswordRequiredError {
                lockPasswordIncorrect = lock.incorrect
                lockPassword = ""
                showingLockPrompt = true
            } catch is AppModel.NeedsUsernameError {
                // New user: prefill a display name and ask for a username.
                if displayName.isEmpty {
                    displayName = Self.suggestedDisplayName(provided: suggestedName, email: session.email)
                }
                go(.setup)
            } catch {
                registrationError = FriendlyError.message(for: error)
            }
        }
    }

    /// The provider's name if it gave one, else the email's local part. Apple's
    /// hidden relay addresses have a random local part, so those start empty.
    static func suggestedDisplayName(provided: String?, email: String) -> String {
        if let provided = provided?.trimmingCharacters(in: .whitespaces), !provided.isEmpty {
            return provided
        }
        let parts = email.lowercased().split(separator: "@")
        guard parts.count == 2, !parts[1].hasSuffix("privaterelay.appleid.com") else { return "" }
        return parts[0]
            .split(whereSeparator: { ".-_+".contains($0) })
            .filter { $0.contains(where: \.isLetter) }
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func finish(session: SignInSession, password: String = "") async throws {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let handle = username.trimmingCharacters(in: .whitespaces)
        try await model.registerWithSignIn(
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

struct BackgroundGradient: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        ZStack {
            // Near-black base with a slowly breathing magenta glow matching the accent.
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
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}

// MARK: - Welcome

/// Shared look for every sign-in button: same height, font, icon box and
/// spacing, with icon and title centred as a unit.
private struct SignInButtonLabel<Icon: View>: View {
    enum Style { case light, outlined }
    let title: String
    let style: Style
    @ViewBuilder let icon: () -> Icon

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            icon().frame(width: 19, height: 19)
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(style == .light ? Color.black : Color.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(style == .light ? Color.white : Color.white.opacity(0.08), in: Self.shape)
        .overlay {
            if style == .outlined {
                Self.shape.strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
        }
        .contentShape(Self.shape)
    }
}

private struct WelcomeView: View {
    let onPhone: () -> Void
    let onEmail: () -> Void
    let onUsernameOnly: () -> Void
    let onSignIn: () -> Void
    /// The session, plus the person's name when the provider gave one (Apple
    /// shares it only on the first sign-in).
    let onOAuthSession: (SignInSession, String?) -> Void
    let onLinkDevice: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var oauthLoading = false
    @State private var oauthError: String?
    @State private var showingProxy = false
    /// The clipboard holds a link: maybe the invite the website copied.
    @State private var clipboardHasLink = false
    @State private var pastedNotInvite = false
    @State private var pendingCodeVerifier: String?
    @State private var googleWebSession: ASWebAuthenticationSession?

    private static let buttonHeight: CGFloat = 52

    /// Who invited you, once known; otherwise a way to paste the invite the
    /// website copied when you tapped Get Relay. The paste button reads the
    /// clipboard only when tapped, so iOS doesn't ask.
    @ViewBuilder private var invite: some View {
        if let url = model.deferredInvite, let link = RelayLink(url) {
            Label(Self.inviteTitle(link), systemImage: link.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white.opacity(0.15), in: .capsule)
                .padding(.top, 6)
                .transition(.scale.combined(with: .opacity))
        } else if clipboardHasLink {
            VStack(spacing: 6) {
                PasteButton(payloadType: String.self) { strings in
                    let url = strings.first.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    withAnimation {
                        pastedNotInvite = !(url.map { model.deferInvite($0) } ?? false)
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(.white.opacity(0.25))
                Text(pastedNotInvite ? "That link isn't a Relay invite." : "Got an invite link? Paste it here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 6)
        }
    }

    private static func inviteTitle(_ link: RelayLink) -> String {
        switch link {
        case .add(let username): "@\(username) invited you"
        case .contactInvite: "You've been invited to chat"
        case .group: "You've been invited to a group"
        case .call: "You've been invited to a call"
        case .proxy: ""
        }
    }

    /// Pattern detection doesn't read the clipboard, so iOS doesn't ask.
    private func checkClipboard() {
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
            let found = (try? result.get())?.contains(.probableWebURL) ?? false
            Task { @MainActor in clipboardHasLink = found }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 18) {
                Image("RelayLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 210)
                    .accessibilityLabel("Relay")
                Text("Private messaging,\nend-to-end encrypted.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                invite
            }

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                if oauthLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.buttonHeight * 4 + 36)
                } else {
                    Button {
                        Task {
                            let nonce = UUID().uuidString + UUID().uuidString
                            handleAppleResult(await AppleSignInFlow.run(scopes: [.email, .fullName], nonce: nonce), nonce: nonce)
                        }
                    } label: {
                        SignInButtonLabel(title: "Continue with Apple", style: .light) {
                            Image(systemName: "apple.logo")
                                .resizable()
                                .scaledToFit()
                                .padding(.bottom, 2)  // the glyph sits low; centre it optically
                        }
                    }
                    .accessibilityLabel("Continue with Apple")

                    Button(action: startGoogleSignIn) {
                        SignInButtonLabel(title: "Continue with Google", style: .light) {
                            GoogleGLogo()
                        }
                    }

                    Button(action: onPhone) {
                        SignInButtonLabel(title: "Continue with Phone", style: .outlined) {
                            Image(systemName: "phone.fill")
                                .resizable()
                                .scaledToFit()
                        }
                    }

                    Button(action: onEmail) {
                        SignInButtonLabel(title: "Continue with Email", style: .outlined) {
                            Image(systemName: "envelope.fill")
                                .resizable()
                                .scaledToFit()
                        }
                    }

                    Button("Sign up with just a username", action: onUsernameOnly)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(minHeight: 36)
                }

                if let oauthError {
                    InlineErrorBanner(oauthError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: onSignIn) {
                    (Text("Already have an account? ").foregroundStyle(.white.opacity(0.6))
                     + Text("Sign in").foregroundStyle(.white).fontWeight(.semibold))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .padding(.top, 4)

                LegalFooter()
                    .padding(.top, 8)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        // Less common ways in live in one menu, keeping the area under the
        // sign-in buttons to sign in and the legal line.
        .overlay(alignment: .topTrailing) {
            Menu {
                Button(action: onLinkDevice) {
                    Label("Link to an Existing Device", systemImage: "qrcode.viewfinder")
                }
                // Where Relay is blocked, sign-in only works through a proxy.
                Button { showingProxy = true } label: {
                    Label(RelayProxy.isEnabled ? "Proxy On" : "Connect Through a Proxy",
                          systemImage: "network.badge.shield.half.filled")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassCompat(in: .circle)
                    .overlay(alignment: .topTrailing) {
                        if RelayProxy.isEnabled {
                            Circle().fill(.green).frame(width: 9, height: 9)
                        }
                    }
            }
            .accessibilityLabel("More sign-in options")
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .onAppear { checkClipboard() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { checkClipboard() } }
        .animation(.spring(duration: 0.35), value: model.deferredInvite)
        .sheet(isPresented: $showingProxy) {
            NavigationStack {
                ProxySettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingProxy = false }
                        }
                    }
            }
            .preferredColorScheme(nil)
        }
    }

    // MARK: Apple

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>, nonce: String) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else {
                oauthError = "Apple Sign In returned an unexpected credential."
                return
            }
            let appleName = cred.fullName.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
            }
            oauthLoading = true
            oauthError = nil
            Task {
                do {
                    let session = try await SignInAuth.shared.signInWithApple(identityToken: token, nonce: nonce)
                    AppleSignInRecord.used = true
                    onOAuthSession(session, appleName)
                } catch {
                    oauthError = FriendlyError.message(for: error)
                }
                oauthLoading = false
            }
        case .failure(let error):
            let asErr = error as? ASAuthorizationError
            if asErr?.code != .canceled {
                // ASAuthorizationError descriptions are raw framework codes.
                oauthError = "Sign in with Apple didn't finish. Please try again."
            }
        }
    }

    // MARK: Google (PKCE via ASWebAuthenticationSession)

    private func startGoogleSignIn() {
        let verifier = makeCodeVerifier()
        let challenge = codeChallenge(from: verifier)
        pendingCodeVerifier = verifier

        guard GoogleSignInConfig.isConfigured,
              let authURL = SignInAuth.googleAuthorizeURL(codeChallenge: challenge)
        else {
            oauthError = "Google sign-in isn't available yet. Use your email address instead."
            return
        }

        oauthLoading = true
        oauthError = nil

        let ws = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: GoogleSignInConfig.redirectScheme
        ) { callbackURL, error in
            googleWebSession = nil
            if let error {
                oauthLoading = false
                let asErr = error as? ASWebAuthenticationSessionError
                if asErr?.code != .canceledLogin {
                    oauthError = "Google sign-in didn't finish. Please try again."
                }
                return
            }
            guard let callbackURL else {
                oauthLoading = false
                return
            }
            Task { await handleGoogleCallback(callbackURL) }
        }
        // Ephemeral: no shared Safari cookies, so Relay sign-in never links to or
        // leaves traces in the user's browser session.
        ws.prefersEphemeralWebBrowserSession = true
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
            oauthError = "Google sign-in didn't finish. Please try again."
            return
        }
        pendingCodeVerifier = nil
        do {
            let session = try await SignInAuth.shared.signInWithGoogle(code: code, verifier: verifier)
            onOAuthSession(session, nil)
        } catch {
            oauthError = FriendlyError.message(for: error)
        }
        oauthLoading = false
    }

    // MARK: PKCE helpers

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
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

// MARK: - Shared field types

enum AuthView {
    enum Field: Hashable { case email, code }

    /// The relay's codes are 6 digits.
    static let validCodeLength = 6...6
}

// MARK: - One-time code sign-in

/// Email, then an emailed one-time code, then a sign-in that follows
/// the Apple/Google path: new emails pick a username; existing accounts sign
/// in, asking for the account password if set.
private struct EmailCodeView: View {
    let onSession: (SignInSession) -> Void
    let onBack: () -> Void

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var resendNote: String?
    @FocusState private var focused: AuthView.Field?

    private var normalizedEmail: String { email.lowercased().trimmingCharacters(in: .whitespaces) }
    private var canContinue: Bool {
        guard !isLoading else { return false }
        return codeSent ? AuthView.validCodeLength.contains(code.count) : normalizedEmail.contains("@")
    }

    var body: some View {
        content
            .modifier(PasskeyAutoFill(enabled: !codeSent, errorMessage: $errorMessage))
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Button {
                        if codeSent {
                            codeSent = false
                            code = ""
                            errorMessage = nil
                        } else {
                            onBack()
                        }
                    } label: {
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
                    Text(codeSent ? "Check your email" : "Sign in with a code")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text(codeSent
                         ? "Enter the code we sent to \(normalizedEmail)."
                         : "We'll email you a one-time code. New here? This creates your account.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.bottom, 12)

                Group {
                    if codeSent {
                        AuthField(icon: "number", placeholder: "Code",
                                  text: $code, focused: $focused, field: .code,
                                  contentType: .oneTimeCode, keyboard: .numberPad)
                    } else {
                        AuthField(icon: "envelope", placeholder: "Email address",
                                  text: $email, focused: $focused, field: .email,
                                  contentType: .username, keyboard: .emailAddress)
                    }
                }
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))

                if let errorMessage {
                    InlineErrorBanner(errorMessage)
                }

                Button(action: codeSent ? verify : sendCode) {
                    ZStack {
                        if isLoading {
                            ProgressView().tint(Color(red: 0.06, green: 0.02, blue: 0.22))
                        } else {
                            Text(codeSent ? "Continue" : "Send code")
                                .font(.headline)
                                // Dark ink only on the white button; greyed out it's white.
                                .foregroundStyle(canContinue ? Color(red: 0.06, green: 0.02, blue: 0.22) : Color.white.opacity(0.55))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canContinue ? Color.white : Color.white.opacity(0.3),
                                in: .rect(cornerRadius: 16, style: .continuous))
                }
                .disabled(!canContinue)

                if codeSent {
                    Button("Resend code", action: sendCode)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .disabled(isLoading)
                    if let resendNote {
                        Text(resendNote)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    LegalFooter().padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = .email }
        .onChange(of: code) { _, new in
            let digits = String(new.filter(\.isNumber).prefix(AuthView.validCodeLength.upperBound))
            if digits != new { code = digits }
        }
    }

    private func sendCode() {
        errorMessage = nil
        isLoading = true
        focused = nil
        let resending = codeSent
        Task {
            do {
                try await SignInAuth.shared.requestSignInCode(email: normalizedEmail)
                code = ""
                codeSent = true
                focused = .code
                resendNote = resending ? "Sent. It can take a minute to arrive — check your spam folder too." : nil
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            isLoading = false
        }
    }

    private func verify() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                let session = try await SignInAuth.shared.verifySignInCode(email: normalizedEmail, code: code)
                onSession(session)
            } catch {
                errorMessage = "That code didn't work. Check it, or tap Resend code."
            }
            isLoading = false
        }
    }
}

/// App Review: one short code signs in to an isolated demo account.
struct ReviewCodeSheet: View {
    var onComplete: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Review code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text(errorMessage ?? "For App Review and testing. The code signs in to a demo account that can only message other demo accounts.")
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Review Sign-In")
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
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 6)
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
                try await model.demoSignIn(serverURL: RelayConfig.serverURL, code: code)
                dismiss()
                onComplete()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)

            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
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

/// Offers saved passkeys in the keyboard's suggestions on a sign-in screen's
/// email field; picking one signs in without anything else.
private struct PasskeyAutoFill: ViewModifier {
    let enabled: Bool
    @Binding var errorMessage: String?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .task(id: enabled) {
                guard enabled else { return }
                do {
                    try await model.signInWithPasskey(autoFill: true)
                } catch PasskeyError.canceled, PasskeyError.unsupported {
                } catch is CancellationError {
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: enabled) { _, on in if !on { model.cancelPasskeyAutoFill() } }
            .onDisappear { model.cancelPasskeyAutoFill() }
    }
}

// MARK: - Setup (display name + username)

private struct SetupView: View {
    @Binding var displayName: String
    @Binding var username: String
    let checkAvailability: (String) async -> AppModel.UsernameAvailability
    let onComplete: () async throws -> Void
    let onBack: () -> Void

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var usernameStatus: UsernameStatus = .idle
    @State private var checkTask: Task<Void, Never>?
    @FocusState private var focused: SetupField?

    enum SetupField: Hashable { case displayName, username }

    enum UsernameStatus: Equatable {
        case idle, checking, available, taken, unknown, invalid(String)
    }

    private var displayNameReserved: Bool { ReservedNames.isReserved(displayName) }

    private var canContinue: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty, !displayNameReserved, !isLoading else { return false }
        if case .available = usernameStatus { return true }
        return false
    }

    var body: some View {
        // ScrollView rather than Spacers so the keyboard never covers the "Start
        // messaging" button on small phones.
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
                    .accessibilityLabel("Back")
                    .disabled(isLoading)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.bottom, 8)
                        .accessibilityHidden(true)
                    Text("Set up your profile")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Seen by the people you message.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 24)
                .padding(.bottom, 36)

                VStack(spacing: 0) {
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

                    HStack(spacing: 12) {
                        Text("@")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24)
                        TextField("username", text: $username)
                            .focused($focused, equals: .username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
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

                if displayNameReserved {
                    Text("That display name is reserved. Please choose another.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }

                if let errorMessage {
                    InlineErrorBanner(errorMessage)
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                }

                Button {
                    focused = nil
                    isLoading = true
                    errorMessage = nil
                    Task {
                        do {
                            try await onComplete()
                        } catch PasskeyError.canceled {
                            // Backed out of the passkey sheet: nothing went wrong.
                            isLoading = false
                        } catch {
                            errorMessage = FriendlyError.message(for: error)
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
                                .foregroundStyle(canContinue ? Color(red: 0.06, green: 0.02, blue: 0.22) : Color.white.opacity(0.55))
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
                .padding(.top, 28)

                LegalFooter()
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var usernameStatusIcon: some View {
        switch usernameStatus {
        case .idle:           EmptyView()
        case .checking:       ProgressView().scaleEffect(0.75).tint(.white.opacity(0.6))
        case .available:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unknown:        Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange.opacity(0.9))
        case .taken, .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.8))
        }
    }

    @ViewBuilder
    private var usernameStatusLabel: some View {
        switch usernameStatus {
        case .idle:
            Text(UsernameRules.hint)
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
        case .unknown:
            Text("Couldn't check — you're offline")
                .font(.caption).foregroundStyle(.orange.opacity(0.9))
        case .invalid(let reason):
            Text(reason)
                .font(.caption).foregroundStyle(.orange.opacity(0.9)).multilineTextAlignment(.center)
        }
    }

    private func scheduleCheck(_ raw: String) {
        let lower = raw.lowercased()
        if lower != raw { username = lower; return }

        checkTask?.cancel()
        guard !lower.isEmpty else { usernameStatus = .idle; return }

        if let reason = UsernameRules.validationError(lower) { usernameStatus = .invalid(reason); return }

        usernameStatus = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let availability = await checkAvailability(lower)
            guard !Task.isCancelled else { return }
            switch availability {
            case .available: usernameStatus = .available
            case .taken:     usernameStatus = .taken
            case .unknown:   usernameStatus = .unknown
            }
        }
    }
}

// MARK: - Legal footer

/// "By continuing you agree to…" with tappable Terms / Privacy Policy links.
/// Shown on every onboarding screen that creates or signs into an account.
struct LegalFooter: View {
    var body: some View {
        // Literal URLs, not interpolated, so SwiftUI parses the Markdown links.
        Text("By continuing you agree to our [Terms](https://relaymsg.app/terms) and [Privacy Policy](https://relaymsg.app/privacy).")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .tint(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// Public legal/support URLs. The pages must be live before App Review.
enum LegalLinks {
    static let terms = URL(string: "https://relaymsg.app/terms")!
    static let privacy = URL(string: "https://relaymsg.app/privacy")!
    static let supportEmail = "support@relaymsg.app"
    static let feedbackMail = URL(string: "mailto:support@relaymsg.app?subject=Relay%20Feedback")!
}

// MARK: - Username rules

/// Client-side username validation shared by onboarding and Change Username.
/// ASCII only: a-z, 0-9 and underscore, 3-20 characters.
enum UsernameRules {
    static let hint = "Lowercase letters (a–z), digits and underscores. 3–20 characters."

    static func validationError(_ u: String) -> String? {
        if u.count < 3  { return "Too short — minimum 3 characters." }
        if u.count > 20 { return "Too long — maximum 20 characters." }
        let ok = u.unicodeScalars.allSatisfy { s in
            (s >= "a" && s <= "z") || (s >= "0" && s <= "9") || s == "_"
        }
        if !ok { return "Only a–z, 0–9 and underscores." }
        if ReservedNames.isReserved(u) { return "That name is reserved. Please choose another." }
        return nil
    }
}

// MARK: - Friendly errors

/// Maps raw network/server/auth errors to short messages for onboarding and
/// settings, falling back to the error's own description.
enum FriendlyError {
    static func message(for error: Error) -> String {
        if let setup = error as? AppModel.SetupError {
            return message(for: setup.underlying)
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return offline
            case .networkConnectionLost:
                return "The connection dropped. Please try again."
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return unreachable
            case .cancelled:
                return "The request was cancelled. Please try again."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "Couldn't make a secure connection to Relay. If you're on public Wi-Fi, try another network."
            default:
                return unreachable
            }
        }
        if error is CancellationError {
            return "The request was cancelled. Please try again."
        }
        if let api = error as? RelayAPIError {
            switch api {
            case .http(let status, let serverMessage):
                switch status {
                case 409 where serverMessage.isEmpty || serverMessage.localizedCaseInsensitiveContains("username"):
                    return "That username was just taken. Please choose another."
                case 429: return tooMany
                case 500...599: return "Relay is having trouble right now. Please try again shortly."
                default:
                    // The relay's errors are short lower-case phrases; present them as a
                    // sentence instead of "Server error (HTTP n)".
                    if !serverMessage.isEmpty { return sentence(serverMessage) }
                    return "Something went wrong talking to Relay. Please try again."
                }
            case .rateLimited:
                return tooMany
            case .malformedResponse:
                return "Relay sent an unexpected response. Please try again."
            }
        }
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        // Swift errors without a description bridge to Foundation's generic "The
        // operation couldn't be completed. (Module.Type error 1.)"; never show
        // type names to people.
        let text = error.localizedDescription
        if text.contains("couldn’t be completed") || text.contains("couldn't be completed") {
            return generic
        }
        return text
    }

    /// "device list changed; retry" becomes "Device list changed; retry."
    private static func sentence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return generic }
        var s = first.uppercased() + trimmed.dropFirst()
        if let last = s.last, !".!?".contains(last) { s += "." }
        return s
    }

    private static let generic = "Something went wrong. Please try again."

    private static let offline = "You're offline. Check your connection and try again."
    private static let unreachable = "Couldn't reach Relay. Please try again in a moment."
    private static let tooMany = "Too many attempts. Please wait a minute and try again."
}
