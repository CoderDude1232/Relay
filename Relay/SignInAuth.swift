//
//  SignInAuth.swift
//  Relay
//
//  Signing in with an email code, Apple or Google, checked by the relay itself
//  (server identity.go): no sign-in service holds the address or the account.
//  Each way ends in a short-lived ticket that the account endpoints accept as
//  the sign-in token.
//

import AuthenticationServices
import CryptoKit
import Foundation
import RelayKit
import Security

/// A verified sign-in, good for about 15 minutes.
struct SignInSession: Sendable {
    let accessToken: String
    /// Kept for the saved-account check; tickets don't carry an id.
    let userId: String
    let email: String
}

/// The app's Google OAuth client (an iOS client in Google Cloud Console). The
/// relay's -google-client-id must be the same id.
enum GoogleSignInConfig {
    static let clientID = "447181060647-3dad9o89v72fvrip8ir9e5a1rl2o6tlb.apps.googleusercontent.com"
    static var isConfigured: Bool { !clientID.isEmpty }
    /// The reversed client id, Google's redirect scheme for iOS clients.
    static var redirectScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }
    static var redirectURI: String { redirectScheme + ":/oauth2redirect" }
}

actor SignInAuth {

    static let shared = SignInAuth()

    /// The last verified sign-in, in memory only.
    private(set) var session: SignInSession?

    init() {
        Self.deleteLegacySupabaseSession()
    }

    private var api: RelayAPIClient {
        RelayAPIClient(baseURL: RelayConfig.serverURL, credentials: nil, session: RelayTLS.sharedSession)
    }

    // MARK: Email code

    func requestSignInCode(email: String) async throws {
        try await api.requestEmailCode(email)
    }

    func verifySignInCode(email: String, code: String) async throws -> SignInSession {
        let ticket = try await api.verifyEmailCode(email, code: code)
        return store(ticket, fallbackEmail: email)
    }

    // MARK: Apple

    /// `nonce` is the raw nonce whose SHA-256 went into the Apple request.
    func signInWithApple(identityToken: String, nonce: String) async throws -> SignInSession {
        store(try await api.signInTicket(appleIdentityToken: identityToken, nonce: nonce), fallbackEmail: "")
    }

    // MARK: Google

    /// Google's sign-in page for the app's client, with PKCE.
    nonisolated static func googleAuthorizeURL(codeChallenge: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleSignInConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleSignInConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components?.url
    }

    /// Exchanges Google's code for its ID token (iOS clients have no secret;
    /// PKCE proves the request), then has the relay check the token.
    func signInWithGoogle(code: String, verifier: String) async throws -> SignInSession {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: GoogleSignInConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleSignInConfig.redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        struct TokenResponse: Decodable { let id_token: String }
        let (data, response) = try await RelayTLS.sharedAnonymousSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { throw SignInError.failed("Google sign-in didn't finish. Please try again.") }
        return store(try await api.signInTicket(googleIDToken: token.id_token), fallbackEmail: "")
    }

    // MARK: Session

    func signOut() {
        session = nil
    }

    private func store(_ ticket: RelayAPIClient.SignInTicket, fallbackEmail: String) -> SignInSession {
        let s = SignInSession(accessToken: ticket.token, userId: "",
                              email: ticket.email.isEmpty ? fallbackEmail : ticket.email)
        session = s
        return s
    }

    /// Older versions kept a Supabase session in the Keychain; it's no longer
    /// used, so it shouldn't linger.
    private static func deleteLegacySupabaseSession() {
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrService: "com.relayapp.relay.supabase",
                       kSecAttrAccount: "session"] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "supabase.session")
    }
}

enum SignInError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
