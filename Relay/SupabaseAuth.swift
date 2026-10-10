//
//  SupabaseAuth.swift
//  Relay
//
//  Minimal Supabase auth client over URLSession.
//

import Foundation
import Security

// MARK: - Config

enum SupabaseConfig {
    static let projectURL = "https://kmhxqtouqlfefzaedoqx.supabase.co"
    static let anonKey    = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImttaHhxdG91cWxmZWZ6YWVkb3F4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY4MjI1NjEsImV4cCI6MjEwMjM5ODU2MX0.9uwaGRkEGNa6G6ZvJYTQ5oAw04JXHf4rEiqlCfpCP3E"
}

// MARK: - Session

struct SupabaseSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let userId: String
    let email: String
}

// MARK: - Auth actor

actor SupabaseAuth {

    static let shared = SupabaseAuth()

    private(set) var session: SupabaseSession?

    // Legacy UserDefaults key, read only for migration.
    private static let legacySessionKey = "supabase.session"

    init() {
        // Load from Keychain, falling back to legacy UserDefaults for migration.
        if let data = Self.kcLoad() ?? Self.migrateFromUserDefaults(),
           let saved = try? JSONDecoder().decode(SupabaseSession.self, from: data) {
            session = saved
        }
    }

    // MARK: - Public API

    enum SignUpResult {
        /// Email confirmation is off: signed in straight away.
        case signedIn(SupabaseSession)
        /// Supabase emailed a code (6–10 digits); verify it with `verifySignUpCode`.
        case confirmationRequired
    }

    func signUp(email: String, password: String) async throws -> SignUpResult {
        let data = try await send(path: "/auth/v1/signup", body: ["email": email, "password": password])
        // With "Confirm email" on, Supabase returns the user without a session.
        guard let raw = try? JSONDecoder().decode(SupabaseRawSession.self, from: data) else {
            // For an already registered address Supabase sends no email and
            // returns a user with no identities, so no code will arrive.
            if let pending = try? JSONDecoder().decode(SupabasePendingUser.self, from: data),
               let identities = pending.identities ?? pending.user?.identities,
               identities.isEmpty {
                throw SupabaseError.emailAlreadyRegistered
            }
            return .confirmationRequired
        }
        return .signedIn(store(raw))
    }

    /// Exchanges the code from the confirmation email for a session.
    func verifySignUpCode(email: String, code: String) async throws -> SupabaseSession {
        try await post(path: "/auth/v1/verify", body: ["type": "signup", "email": email, "token": code])
    }

    /// Sends the confirmation email again.
    func resendSignUpCode(email: String) async throws {
        _ = try await send(path: "/auth/v1/resend", body: ["type": "signup", "email": email])
    }

    // MARK: One-time code sign-in (passwordless)

    /// Emails a one-time sign-in code. New addresses get an account created
    /// (Supabase sends its "Confirm signup" email); existing ones get the
    /// "Magic Link" email. Both carry the same kind of code.
    func requestSignInCode(email: String) async throws {
        _ = try await send(path: "/auth/v1/otp", body: ["email": email])
    }

    /// Exchanges a one-time sign-in code for a session.
    func verifySignInCode(email: String, code: String) async throws -> SupabaseSession {
        try await post(path: "/auth/v1/verify", body: ["type": "email", "email": email, "token": code])
    }

    // MARK: Password reset ("forgot password")

    /// Emails a password-recovery code to `email`. Supabase answers the same
    /// whether or not the address is registered.
    func requestPasswordReset(email: String) async throws {
        _ = try await send(path: "/auth/v1/recover", body: ["email": email])
    }

    /// Exchanges the recovery code for a session. The relay accepts only a
    /// session created this way (and recently) for a password reset.
    func verifyRecoveryCode(email: String, code: String) async throws -> SupabaseSession {
        try await post(path: "/auth/v1/verify", body: ["type": "recovery", "email": email, "token": code])
    }

    /// Sets the Supabase password for the signed-in user (kept in step with
    /// the Relay account password after a reset).
    func updatePassword(_ password: String) async throws {
        let token = try await validAccessToken()
        _ = try await send(path: "/auth/v1/user", body: ["password": password], method: "PUT", bearer: token)
    }

    // MARK: Email change

    /// Asks Supabase to change the signed-in user's email; it emails a code to
    /// the new address.
    func requestEmailChange(to newEmail: String) async throws {
        let token = try await validAccessToken()
        _ = try await send(path: "/auth/v1/user", body: ["email": newEmail], method: "PUT", bearer: token)
    }

    /// Confirms the change with the code from the new address, then refreshes
    /// the session so it carries the new email.
    func verifyEmailChange(newEmail: String, code: String) async throws -> SupabaseSession {
        let token = try await validAccessToken()
        _ = try await send(path: "/auth/v1/verify",
                           body: ["type": "email_change", "email": newEmail, "token": code],
                           bearer: token)
        return try await refresh()
    }

    /// The current access token, refreshed first so it's never stale.
    private func validAccessToken() async throws -> String {
        guard session != nil else { throw SupabaseError.noSession }
        return try await refresh().accessToken
    }

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        try await post(path: "/auth/v1/token?grant_type=password",
                       body: ["email": email, "password": password])
    }

    func signOut() {
        session = nil
        Self.kcDelete()
        UserDefaults.standard.removeObject(forKey: Self.legacySessionKey)
    }

    /// Exchanges the stored refresh token for a new token pair. Call on a 401.
    @discardableResult
    func refresh() async throws -> SupabaseSession {
        guard let current = session else {
            throw SupabaseError.server("No active session to refresh.")
        }
        return try await post(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": current.refreshToken]
        )
    }

    /// Exchange an Apple identity token for a Supabase session (OIDC id_token grant).
    func signInWithApple(identityToken: String) async throws -> SupabaseSession {
        try await post(path: "/auth/v1/token?grant_type=id_token",
                       body: ["provider": "apple", "id_token": identityToken])
    }

    /// Exchange a Google PKCE authorization code for a Supabase session.
    func exchangeOAuthCode(_ code: String, verifier: String) async throws -> SupabaseSession {
        try await post(path: "/auth/v1/token?grant_type=pkce",
                       body: ["auth_code": code, "code_verifier": verifier])
    }

    // MARK: - Private

    private func post(path: String, body: [String: String]) async throws -> SupabaseSession {
        let data = try await send(path: path, body: body)
        return store(try JSONDecoder().decode(SupabaseRawSession.self, from: data))
    }

    private func store(_ raw: SupabaseRawSession) -> SupabaseSession {
        let s = SupabaseSession(accessToken: raw.access_token,
                                refreshToken: raw.refresh_token,
                                userId: raw.user.id,
                                email: raw.user.email ?? "")
        session = s
        if let encoded = try? JSONEncoder().encode(s) {
            Self.kcSave(encoded)
        }
        return s
    }

    /// `bearer` is the user's access token for calls made as the signed-in user;
    /// otherwise the request is made with the project's public anon key.
    private func send(path: String, body: [String: String], method: String = "POST",
                      bearer: String? = nil) async throws -> Data {
        guard let url = URL(string: SupabaseConfig.projectURL + path) else {
            throw SupabaseError.badConfig
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let urlErr as URLError {
            switch urlErr.code {
            case .notConnectedToInternet:
                throw SupabaseError.server("No internet connection.")
            case .cannotConnectToHost:
                throw SupabaseError.server("Cannot reach Supabase. Check your connection.")
            case .timedOut:
                throw SupabaseError.server("Request timed out.")
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .serverCertificateHasBadDate:
                throw SupabaseError.server("Supabase TLS error: server certificate not trusted.")
            default:
                throw SupabaseError.server("Network error: \(urlErr.localizedDescription)")
            }
        }

        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let decoded = try? JSONDecoder().decode(SupabaseErrorBody.self, from: data)
            let bodyMsg = decoded?.message ?? decoded?.msg ?? decoded?.error_description
            let rawSnippet = bodyMsg == nil
                ? (String(data: data.prefix(200), encoding: .utf8).map { " — \($0)" } ?? "")
                : ""
            let msg = bodyMsg ?? "Authentication failed"
            throw SupabaseError.server("HTTP \(http.statusCode): \(msg)\(rawSnippet)")
        }
        return data
    }

    // MARK: - Keychain

    private static let kcService = "com.relayapp.relay.supabase"
    private static let kcAccount = "session"

    private static func kcQuery() -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: kcService,
         kSecAttrAccount: kcAccount]
    }

    private static func kcSave(_ data: Data) {
        var attrs = kcQuery()
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecValueData] = data
        SecItemDelete(kcQuery() as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func kcLoad() -> Data? {
        var attrs = kcQuery()
        attrs[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attrs as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func kcDelete() {
        SecItemDelete(kcQuery() as CFDictionary)
    }

    /// Reads from the legacy UserDefaults location, saves to Keychain, and clears UserDefaults.
    private static func migrateFromUserDefaults() -> Data? {
        guard let data = UserDefaults.standard.data(forKey: legacySessionKey) else { return nil }
        kcSave(data)
        UserDefaults.standard.removeObject(forKey: legacySessionKey)
        return data
    }
}

// MARK: - Response shapes

private struct SupabaseRawSession: Decodable, Sendable {
    let access_token: String
    let refresh_token: String
    let user: SupabaseUser
}
private struct SupabaseUser: Decodable, Sendable { let id: String; let email: String? }
/// Sign-up response when confirmation is required: the user object, either at
/// the top level or under `user` depending on the Supabase version.
private struct SupabasePendingUser: Decodable, Sendable {
    struct Inner: Decodable, Sendable { let identities: [Identity]? }
    struct Identity: Decodable, Sendable {}
    let identities: [Identity]?
    let user: Inner?
}
private struct SupabaseErrorBody: Decodable, Sendable {
    let message: String?
    let msg: String?
    /// OAuth-style errors (e.g. the id_token grant) use these instead.
    let error_description: String?
}

// MARK: - Errors

enum SupabaseError: LocalizedError {
    case badConfig
    case server(String)
    case emailAlreadyRegistered
    case noSession

    var isNoSession: Bool {
        if case .noSession = self { true } else { false }
    }

    var errorDescription: String? {
        switch self {
        case .badConfig: "Supabase is not configured. Update SupabaseConfig in SupabaseAuth.swift."
        case .noSession:
            "This device isn't signed in with your email account. Make this change from the device you signed up on."
        case .emailAlreadyRegistered:
            "This email already has a Relay account. Go back and tap Sign in to use it on this device."
        case .server(let m): m
        }
    }
}
