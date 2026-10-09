//
//  SupabaseAuth.swift
//  Relay
//
//  Lightweight Supabase auth — no SDK dependency, plain URLSession.
//  Update SupabaseConfig once you have a project (see setup steps in README).
//

import Foundation
import Security

// MARK: - Config  (update these after creating your Supabase project)

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

    // Legacy UserDefaults key — only read for one-time migration.
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
        /// Supabase emailed a 6-digit code; verify it with `verifySignUpCode`.
        case confirmationRequired
    }

    func signUp(email: String, password: String) async throws -> SignUpResult {
        let data = try await send(path: "/auth/v1/signup", body: ["email": email, "password": password])
        // With "Confirm email" on, Supabase returns the user without a session.
        guard let raw = try? JSONDecoder().decode(SupabaseRawSession.self, from: data) else {
            return .confirmationRequired
        }
        return .signedIn(store(raw))
    }

    /// Exchanges the 6-digit code from the confirmation email for a session.
    func verifySignUpCode(email: String, code: String) async throws -> SupabaseSession {
        try await post(path: "/auth/v1/verify", body: ["type": "signup", "email": email, "token": code])
    }

    /// Sends the confirmation email again.
    func resendSignUpCode(email: String) async throws {
        _ = try await send(path: "/auth/v1/resend", body: ["type": "signup", "email": email])
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

    /// Exchanges the stored refresh token for a fresh access + refresh token pair.
    /// Call this when a Supabase API call returns 401 (token expired).
    /// Returns the refreshed session, or throws if no session exists or the refresh fails.
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

    private func send(path: String, body: [String: String]) async throws -> Data {
        guard let url = URL(string: SupabaseConfig.projectURL + path) else {
            throw SupabaseError.badConfig
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
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
            let bodyMsg = decoded?.message ?? decoded?.msg
            let rawSnippet = bodyMsg == nil
                ? (String(data: data.prefix(200), encoding: .utf8).map { " — \($0)" } ?? "")
                : ""
            let msg = bodyMsg ?? "Authentication failed"
            throw SupabaseError.server("HTTP \(http.statusCode): \(msg)\(rawSnippet)")
        }
        return data
    }

    // MARK: - Keychain (access + refresh tokens are credentials; use Keychain)

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
private struct SupabaseErrorBody: Decodable, Sendable {
    let message: String?
    let msg: String?
}

// MARK: - Errors

enum SupabaseError: LocalizedError {
    case badConfig
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badConfig: "Supabase is not configured. Update SupabaseConfig in SupabaseAuth.swift."
        case .server(let m): m
        }
    }
}
