//
//  RelayAPIClient.swift
//  RelayKit
//
//  The relay's JSON REST API: accounts, devices, prekeys. Binary fields are
//  standard base64, as in server/README.md.
//
//  Two transports:
//   - `session`: authenticated calls, each signed with Relay-Sig v2. HTTP Basic
//     is used only to register a device's first auth key; a failed signature
//     never falls back to Basic.
//   - `anonymousSession`: a separate ephemeral session for requests that must
//     not be linkable to the logged-in connection (sealed sends, call rings,
//     attachments, invite claims, sign-up and recovery). No credentials, no
//     shared connection.
//

import CryptoCore
import Foundation
import Security

/// One resolved blinded-directory match.
public struct DirectoryMatch: Sendable, Equatable {
    public let token: Data
    public let accountId: String
    public let username: String
    /// The account's sealed-sender access key, if the relay serves it.
    public let accessKey: Data?

    public init(token: Data, accountId: String, username: String, accessKey: Data? = nil) {
        self.token = token
        self.accountId = accountId
        self.username = username
        self.accessKey = accessKey
    }
}

public enum RelayAPIError: Error, LocalizedError {
    case http(status: Int, message: String)
    /// HTTP 429 from any endpoint. Separate from `.http` so callers back off
    /// instead of failing; `retryAfter` is the Retry-After header, if sent.
    case rateLimited(message: String, retryAfter: TimeInterval?)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            return message.isEmpty ? "Server error (HTTP \(status))." : message
        case .rateLimited:
            return "Too many requests right now. Please try again shortly."
        case .malformedResponse:
            return "The server sent an unexpected response."
        }
    }
}

/// The account password as sent to the relay. `key` is derived from the
/// password on the device (see the app's AccountPasswordKey), so the relay never
/// sees the password itself. `legacy` is the raw password, sent only once, next
/// to the key, when the relay answers 428 for an account whose hash predates
/// keys; it then stores a hash of the key instead.
public struct AccountPasswordProof: Sendable {
    public let key: String
    public var legacy: String?

    public init(key: String, legacy: String? = nil) {
        self.key = key
        self.legacy = legacy
    }

    /// 428: the account's password needs its one-time upgrade (send `legacy` too).
    public static let upgradeRequiredStatus = 428

    func addFields(to body: inout [String: String]) {
        body["accountPasswordKey"] = key
        if let legacy, !legacy.isEmpty { body["accountPassword"] = legacy }
    }
}

/// Result of a Supabase social-login provisioning call.
public enum OAuthProvisionOutcome: Sendable {
    /// New device credentials, the account's username, and whether this call
    /// created the account.
    case signedIn(credentials: RelayCredentials, username: String, created: Bool)
    /// No account exists and no username was given; prompt for one and retry.
    case usernameRequired
    /// The account has a password (registration lock), needed to sign in on a
    /// new device since that replaces the account's devices. `incorrect` is true
    /// if one was given and didn't match.
    case accountPasswordRequired(incorrect: Bool)
    /// The account needs a second step; finish with `completeTwoStep`.
    case twoStepRequired(TwoStepRequired)
}

/// A `423` from a code sign-in: the account wants its second step. The ticket
/// lasts 10 minutes.
public struct TwoStepRequired: Error, Decodable, Sendable, Equatable {
    public enum Method: String, Sendable {
        case authenticator = "totp", passkey, pin, recovery
    }
    public let ticket: String
    public let rawMethod: String
    /// Every method the account has on; an answer to any one passes.
    public let rawMethods: [String]
    /// Whether the account has a recovery key, which always works instead.
    public let recoveryKey: Bool

    public var method: Method? { Method(rawValue: rawMethod) }
    /// The methods on, the account's first one first.
    public var methods: [Method] {
        let all = rawMethods.compactMap(Method.init(rawValue:))
        return all.isEmpty ? [method].compactMap { $0 } : all
    }

    enum CodingKeys: String, CodingKey { case ticket, rawMethod = "method", rawMethods = "methods", recoveryKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try c.decode(String.self, forKey: .ticket)
        rawMethod = try c.decode(String.self, forKey: .rawMethod)
        rawMethods = try c.decodeIfPresent([String].self, forKey: .rawMethods) ?? []
        recoveryKey = try c.decodeIfPresent(Bool.self, forKey: .recoveryKey) ?? false
    }

    public init(ticket: String, method: Method, recoveryKey: Bool) {
        self.ticket = ticket
        self.rawMethod = method.rawValue
        self.rawMethods = [method.rawValue]
        self.recoveryKey = recoveryKey
    }
}

public struct RelayAPIClient: Sendable {
    public let baseURL: URL
    public let credentials: RelayCredentials?
    private let session: URLSession
    private let anonymousSession: URLSession
    private let signer: (any RelayRequestSigner)?
    /// Asks the user to answer the account's second step when the relay wants
    /// it before a sensitive change (403 with `stepUp`); true to retry.
    private let stepUp: (@Sendable () async -> Bool)?
    /// An anonymous send token (server internal/sendtoken) for sealed sends,
    /// sealed key fetches and call rings, so the relay limits them by token
    /// rather than by our address. nil when none is to hand.
    private let sendToken: (@Sendable () async -> String?)?

    /// - Parameters:
    ///   - session: transport for signed requests.
    ///   - anonymousSession: transport for unauthenticated requests. Pass
    ///     `RelayTLS.makeAnonymousSession(pins:)` when pinning.
    ///   - signer: the device auth key. Required once the device has registered
    ///     one, since the relay then refuses Basic.
    public init(baseURL: URL, credentials: RelayCredentials?,
                session: URLSession = RelayTLS.sharedSession,
                anonymousSession: URLSession = RelayTLS.sharedAnonymousSession,
                signer: (any RelayRequestSigner)? = nil,
                stepUp: (@Sendable () async -> Bool)? = nil,
                sendToken: (@Sendable () async -> String?)? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        self.anonymousSession = anonymousSession
        self.signer = signer
        self.stepUp = stepUp
        self.sendToken = sendToken
    }

    // MARK: - Accounts

    /// Creates an account and primary device; needs no credentials.
    /// `supabaseAccessToken` links the account to a Supabase user. The relay
    /// verifies it and stores the email, as a keyed token for recovery and
    /// discovery, only if Supabase reports it confirmed; a raw email is never
    /// accepted. A non-nil accountPassword enables POST /v1/accounts/recover.
    /// Throws `.http(409, ...)` if the username is taken or the sign-in identity
    /// already has an account.
    public func register(username: String, supabaseAccessToken: String? = nil, password: String,
                         accountPassword: AccountPasswordProof? = nil) async throws -> RelayCredentials {
        struct Response: Decodable {
            let accountId: String
            let deviceId: UInt32
        }
        var body: [String: String] = ["username": username, "password": password]
        if let supabaseAccessToken, !supabaseAccessToken.isEmpty { body["supabaseAccessToken"] = supabaseAccessToken }
        accountPassword?.addFields(to: &body)
        let response: Response = try await request(
            "POST", "v1/accounts",
            body: body,
            authenticated: false
        )
        return RelayCredentials(
            accountId: response.accountId,
            deviceId: response.deviceId,
            password: password
        )
    }

    /// App Review sign-in: a short review code signs this device in to one of
    /// the isolated demo accounts, with no email or password.
    public func demoSignIn(code: String) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable {
            let accountId: String
            let username: String
            let deviceId: UInt32
            let devicePassword: String
        }
        let response: Response = try await request(
            "POST", "v1/accounts/demo-signin", body: ["code": code], authenticated: false
        )
        return (RelayCredentials(accountId: response.accountId, deviceId: response.deviceId,
                                 password: response.devicePassword), response.username)
    }

    /// The account's encrypted chat-list blob and its version; nil if none.
    public func accountStorage() async throws -> (blob: Data, version: Int64)? {
        struct Response: Decodable { let blob: String; let version: Int64 }
        do {
            let r: Response = try await request("GET", "v1/accounts/me/storage", body: nil as String?)
            guard let blob = Data(base64Encoded: r.blob) else { throw RelayAPIError.malformedResponse }
            return (blob, r.version)
        } catch RelayAPIError.http(status: 404, _) {
            return nil
        }
    }

    /// Replaces the blob if `baseVersion` is current (0 for none) and returns the
    /// new version. 409 means another device wrote first.
    public func putAccountStorage(_ blob: Data, baseVersion: Int64) async throws -> Int64 {
        struct Body: Encodable { let blob: String; let baseVersion: Int64 }
        struct Response: Decodable { let version: Int64 }
        let r: Response = try await request(
            "PUT", "v1/accounts/me/storage",
            body: Body(blob: blob.base64EncodedString(), baseVersion: baseVersion)
        )
        return r.version
    }

    // MARK: - History backup

    /// One stored segment of the encrypted history backup.
    public struct HistorySegment: Decodable, Sendable {
        public let seq: Int64
        public let size: Int
    }

    /// The account's history segments and its account-wide backup setting.
    public struct HistoryListing: Decodable, Sendable {
        public let segments: [HistorySegment]
        /// nil until one of the account's devices has set it.
        public let enabled: Bool?
    }

    /// The account's history segments (opaque ciphertext numbered by the client).
    public func historyListing() async throws -> HistoryListing {
        try await request("GET", "v1/history", body: nil as String?)
    }

    public func historySegments() async throws -> [HistorySegment] {
        try await historyListing().segments
    }

    /// Sets history backup on or off for every device on the account. Off also
    /// deletes everything stored, and the relay refuses uploads (409) until a
    /// device turns it back on.
    public func setHistoryBackupEnabled(_ enabled: Bool) async throws {
        struct Body: Encodable { let enabled: Bool }
        try await requestExpectingNoContent("PUT", "v1/accounts/me/history-backup", body: Body(enabled: enabled))
    }

    public func putHistorySegment(_ seq: Int64, _ data: Data) async throws {
        var request = makeRequest("PUT", "v1/history/\(seq)")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request, authenticated: true)
    }

    /// Largest history segment the relay stores (2 MiB).
    public static let maxHistorySegmentBytes = 2 << 20

    public func historySegment(_ seq: Int64) async throws -> Data {
        let (data, _) = try await send(makeRequest("GET", "v1/history/\(seq)"), authenticated: true)
        guard data.count <= Self.maxHistorySegmentBytes else { throw RelayAPIError.malformedResponse }
        return data
    }

    public func deleteHistorySegment(_ seq: Int64) async throws {
        _ = try await send(makeRequest("DELETE", "v1/history/\(seq)"), authenticated: true)
    }

    public func deleteAllHistory() async throws {
        _ = try await send(makeRequest("DELETE", "v1/history"), authenticated: true)
    }

    /// Whether this account is a demo account, and the other demo accounts.
    public func demoStatus() async throws -> (demo: Bool, peers: [String]) {
        struct Response: Decodable { let demo: Bool; let peers: [String] }
        let r: Response = try await request("GET", "v1/accounts/me/demo", body: nil as String?)
        return (r.demo, r.peers)
    }

    public func recoverAccount(email: String, accountPassword: AccountPasswordProof) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable {
            let accountId: String
            let username: String
            let deviceId: UInt32
            let devicePassword: String
        }
        var body = ["email": email]
        accountPassword.addFields(to: &body)
        let response: Response = try await request(
            "POST", "v1/accounts/recover", body: body, authenticated: false
        )
        let creds = RelayCredentials(
            accountId: response.accountId,
            deviceId: response.deviceId,
            password: response.devicePassword
        )
        return (creds, response.username)
    }

    /// Forgot password: with a Supabase session from a recovery code, sets a new
    /// account password and provisions this device, replacing the account's
    /// other devices like any fresh sign-in.
    public func resetPassword(supabaseAccessToken: String, newAccountPassword: AccountPasswordProof,
                              devicePassword: String) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable { let accountId: String; let username: String; let deviceId: UInt32 }
        var body = ["accessToken": supabaseAccessToken, "password": devicePassword]
        newAccountPassword.addFields(to: &body)
        let response: Response = try await request(
            "POST", "v1/accounts/password-reset", body: body, authenticated: false
        )
        return (RelayCredentials(accountId: response.accountId, deviceId: response.deviceId,
                                 password: devicePassword), response.username)
    }

    // MARK: Sign-in identities (verified by the relay; server identity.go)

    /// A short-lived ticket from the relay for a verified email, Apple or
    /// Google account, accepted wherever a sign-in token is (`accessToken`).
    public struct SignInTicket: Decodable, Sendable {
        public let token: String
        /// The verified email, or "" when there isn't one.
        public let email: String
    }

    /// Emails a 6-digit code. `reset` is for a forgotten account password.
    public func requestEmailCode(_ email: String, reset: Bool = false) async throws {
        try await requestExpectingNoContent(
            "POST", "v1/email/code", body: ["email": email, "purpose": reset ? "reset" : "signin"], authenticated: false)
    }

    /// Checks an emailed code. 401 means wrong or expired.
    public func verifyEmailCode(_ email: String, code: String) async throws -> SignInTicket {
        try await request("POST", "v1/email/verify", body: ["email": email, "code": code], authenticated: false)
    }

    /// Checks a Sign in with Apple identity token; `nonce` is the raw nonce
    /// whose SHA-256 the app gave Apple.
    public func signInTicket(appleIdentityToken: String, nonce: String) async throws -> SignInTicket {
        try await request("POST", "v1/identity/apple",
                          body: ["identityToken": appleIdentityToken, "nonce": nonce], authenticated: false)
    }

    /// Checks a Google ID token issued to the app's OAuth client.
    public func signInTicket(googleIDToken: String) async throws -> SignInTicket {
        try await request("POST", "v1/identity/google", body: ["idToken": googleIDToken], authenticated: false)
    }

    /// Emails a code to confirm a new address for this account; confirm it
    /// with `verifyEmailCode`, then `updateEmail` with the ticket.
    public func requestEmailChangeCode(_ email: String) async throws {
        try await requestExpectingNoContent("POST", "v1/accounts/me/email/code", body: ["email": email])
    }

    /// Re-keys the account's email token after a confirmed Supabase email change
    /// (`PUT /v1/accounts/me/email`).
    public func updateEmail(supabaseAccessToken: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/accounts/me/email",
                                            body: ["accessToken": supabaseAccessToken])
    }

    /// Signs a Supabase user into their relay account, creating it on first use,
    /// and provisions a new device. The relay verifies the access token with
    /// Supabase, so this is how passwordless social-login accounts sign in on any
    /// device.
    ///
    /// `username` is needed only to create an account. If it is nil and no account
    /// exists, the server returns 404 and this returns `.usernameRequired`.
    /// `devicePassword` is the client-chosen password for the new device.
    public func provisionOAuth(
        accessToken: String, username: String?, devicePassword: String, accountPassword: AccountPasswordProof? = nil
    ) async throws -> OAuthProvisionOutcome {
        struct Response: Decodable {
            let accountId: String
            let deviceId: UInt32
            let username: String
            let created: Bool
        }
        var body: [String: String] = ["accessToken": accessToken, "password": devicePassword]
        if let username, !username.isEmpty { body["username"] = username }
        accountPassword?.addFields(to: &body)
        do {
            let response: Response = try await request(
                "POST", "v1/accounts/oauth", body: body, authenticated: false
            )
            let creds = RelayCredentials(
                accountId: response.accountId,
                deviceId: response.deviceId,
                password: devicePassword
            )
            return .signedIn(credentials: creds, username: response.username, created: response.created)
        } catch RelayAPIError.http(let status, _) where status == 404 {
            return .usernameRequired
        } catch let twoStep as TwoStepRequired {
            return .twoStepRequired(twoStep)
        } catch RelayAPIError.http(423, let message) {
            return .accountPasswordRequired(incorrect: message.contains("incorrect"))
        }
    }

    /// Sets the account password, used for email recovery and as the registration
    /// lock on new-device sign-ins (`PUT /v1/accounts/me/account-password`).
    public func setAccountPassword(_ password: AccountPasswordProof) async throws {
        var body: [String: String] = [:]
        password.addFields(to: &body)
        try await requestExpectingNoContent("PUT", "v1/accounts/me/account-password", body: body)
    }

    /// Opts in or out of email discovery in blinded discovery. Off by default
    /// (`PUT /v1/accounts/me/discoverability`).
    public func setEmailDiscoverable(_ discoverable: Bool) async throws {
        struct Body: Encodable { let email: Bool }
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/discoverability", body: Body(email: discoverable))
    }

    // MARK: Optional phone number (discovery only)

    public struct PhoneStatus: Decodable, Sendable {
        public let hasPhone: Bool
        public let discoverable: Bool
        /// False until the relay is set up to text codes.
        public let available: Bool
        /// Calling codes the relay accepts ("+61"); nil from older relays.
        public let allowedPrefixes: [String]?
    }

    /// `GET /v1/accounts/me/phone`.
    public func phoneStatus() async throws -> PhoneStatus {
        try await request("GET", "v1/accounts/me/phone", body: nil as String?)
    }

    /// Texts a code to `phone` (E.164, e.g. +61412345678).
    public func startPhoneVerification(_ phone: String) async throws {
        struct Body: Encodable { let phone: String }
        try await requestExpectingNoContent("POST", "v1/accounts/me/phone/start", body: Body(phone: phone))
    }

    /// Checks the texted code; on success the number is the account's.
    public func verifyPhone(_ phone: String, code: String, discoverable: Bool) async throws {
        struct Body: Encodable { let phone: String; let code: String; let discoverable: Bool }
        try await requestExpectingNoContent(
            "POST", "v1/accounts/me/phone/verify", body: Body(phone: phone, code: code, discoverable: discoverable))
    }

    public func setPhoneDiscoverable(_ discoverable: Bool) async throws {
        struct Body: Encodable { let discoverable: Bool }
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/phone/discoverability", body: Body(discoverable: discoverable))
    }

    public func removePhone() async throws {
        _ = try await send(makeRequest("DELETE", "v1/accounts/me/phone"), authenticated: true)
    }

    // MARK: Relay Supporter (anonymous credentials; see server README)

    public struct SupporterStatus: Decodable, Sendable {
        public let available: Bool
        /// Unix ms; 0 = never a supporter.
        public let supporterUntil: Int64
    }

    public struct SupporterCredentialRequest: Encodable, Sendable {
        public let period: String
        public let blinded: Data
        public init(period: String, blinded: Data) { self.period = period; self.blinded = blinded }
    }

    public struct IssuedSupporterCredential: Decodable, Sendable {
        public let period: String
        public let evaluated: Data
        public let proof: Data
    }

    /// `GET /v1/supporter/keys`: each period's public key. Unauthenticated.
    public func supporterKeys() async throws -> [String: Data] {
        struct Response: Decodable { let keys: [String: Data] }
        let r: Response = try await request("GET", "v1/supporter/keys", body: nil as String?, authenticated: false)
        return r.keys
    }

    /// Trades an App Store transaction for blinded credentials.
    /// Unauthenticated, so the relay can't tie the purchase to this account.
    public func issueSupporterCredentials(
        transaction: String, requests: [SupporterCredentialRequest]
    ) async throws -> [IssuedSupporterCredential] {
        struct Body: Encodable { let transaction: String; let requests: [SupporterCredentialRequest] }
        struct Response: Decodable { let credentials: [IssuedSupporterCredential] }
        let r: Response = try await request(
            "POST", "v1/supporter/issue", body: Body(transaction: transaction, requests: requests),
            authenticated: false)
        return r.credentials
    }

    /// Redeems one credential on this account; returns supporterUntil (unix ms).
    public func redeemSupporterCredential(period: String, nonce: Data, credential: Data) async throws -> Int64 {
        struct Body: Encodable { let period: String; let nonce: Data; let credential: Data }
        struct Response: Decodable { let supporterUntil: Int64 }
        let r: Response = try await request(
            "POST", "v1/supporter/redeem", body: Body(period: period, nonce: nonce, credential: credential))
        return r.supporterUntil
    }

    public func supporterStatus() async throws -> SupporterStatus {
        try await request("GET", "v1/accounts/me/supporter", body: nil as String?)
    }

    /// Whether `name` is free (case-insensitive). Unauthenticated, rate-limited
    /// per IP, and returns only a boolean. Throws `.http(400, ...)` for an
    /// invalid username.
    public func usernameAvailable(_ name: String) async throws -> Bool {
        struct Response: Decodable { let available: Bool }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let response: Response = try await request(
            "GET", "v1/usernames/\(encoded)/available", body: nil as [String: String]?,
            authenticated: false
        )
        return response.available
    }

    /// Blinded discovery step 1: sends client-blinded ristretto elements and
    /// returns the OPRF evaluations (k*B). Each element spends from a daily
    /// per-account budget.
    public func directoryEvaluate(blinded: [Data]) async throws -> [Data] {
        struct Req: Encodable { let blinded: [String] }
        struct Response: Decodable { let evaluated: [String] }
        let r: Response = try await request(
            "POST", "v1/directory/oprf",
            body: Req(blinded: blinded.map { $0.base64EncodedString() })
        )
        return r.evaluated.compactMap { Data(base64Encoded: $0) }
    }

    /// Blinded discovery step 2: resolves OPRF tokens to accounts without sending
    /// them. Only each token's 16-bit bucket goes to the relay; matching and
    /// decryption happen here. Unmatched tokens are omitted.
    public func directoryResolve(tokens: [Data]) async throws -> [DirectoryMatch] {
        guard !tokens.isEmpty else { return [] }
        var byBucket: [UInt16: [Data]] = [:]
        for token in tokens {
            byBucket[DirectoryBuckets.bucket(for: token), default: []].append(token)
        }
        var matches: [DirectoryMatch] = []
        // Pad with random decoy buckets, in random order. A bucket holds few
        // accounts while Relay is small, so the real one alone would tell the
        // relay whom we looked up; among hundreds it's one of many. (Bounded so
        // the response stays small as buckets fill up.)
        let buckets = DirectoryBuckets.paddedRequest(real: Set(byBucket.keys))
        var start = 0
        while start < buckets.count {
            let chunk = Array(buckets[start..<min(start + DirectoryBuckets.maxBucketsPerRequest, buckets.count)])
            let entries = try await directoryBuckets(chunk)
            for bucket in chunk {
                for token in byBucket[bucket] ?? [] {
                    if let hit = DirectoryBuckets.match(token: token, in: entries[bucket] ?? []) {
                        matches.append(DirectoryMatch(token: token, accountId: hit.accountId,
                                                      username: hit.username, accessKey: hit.accessKey))
                    }
                }
            }
            start += chunk.count
        }
        return matches
    }

    /// Every entry the relay holds in each requested bucket
    /// (`POST /v1/directory/buckets`). Prefer `directoryResolve(tokens:)`.
    public func directoryBuckets(_ buckets: [UInt16]) async throws -> [UInt16: [DirectoryBucketEntry]] {
        struct Req: Encodable { let buckets: [UInt16] }
        struct EntryDTO: Decodable { let tag: String; let box: String; let accessBox: String? }
        struct BucketDTO: Decodable { let bucket: UInt16; let entries: [EntryDTO] }
        struct Response: Decodable { let buckets: [BucketDTO] }
        let r: Response = try await request("POST", "v1/directory/buckets", body: Req(buckets: buckets))
        var out: [UInt16: [DirectoryBucketEntry]] = [:]
        for b in r.buckets {
            out[b.bucket] = b.entries.compactMap { e in
                guard let tag = Data(base64Encoded: e.tag), let box = Data(base64Encoded: e.box) else { return nil }
                return DirectoryBucketEntry(tag: tag, box: box, accessBox: e.accessBox.flatMap { Data(base64Encoded: $0) })
            }
        }
        return out
    }

    /// Changes the account's username. Throws `.http(409, ...)` if taken.
    public func updateUsername(_ username: String) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/username",
            body: ["username": username]
        )
    }

    /// Mints a single-use contact invite token. The first person to open the
    /// link resolves to this account and spends the token.
    public func createContactInvite() async throws -> (token: String, expiresAt: Int64) {
        struct Response: Decodable { let token: String; let expiresAt: Int64 }
        let r: Response = try await request("POST", "v1/contact-invites", body: nil as [String: String]?)
        return (r.token, r.expiresAt)
    }

    /// Redeems a contact invite, returning the inviter's account id and username.
    /// Throws `.http(404, ...)` if invalid, expired or used. Sent anonymously so
    /// the relay can't record who redeemed it.
    public func claimContactInvite(token: String) async throws -> (accountId: String, username: String) {
        struct Response: Decodable { let accountId: String; let username: String }
        let r: Response = try await request(
            "POST", "v1/contact-invites/claim", body: ["token": token], authenticated: false
        )
        return (r.accountId, r.username)
    }

    /// Uploads the account's 32-byte sealed-sender access key. Senders present it
    /// on the unauthenticated path; rotating it revokes old senders.
    public func setAccessKey(_ key: Data) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/access-key",
            body: ["accessKey": key.base64EncodedString()]
        )
    }

    /// Rotates this device's opaque mailbox id and returns the new one. Only on
    /// explicit need, such as a suspected leak, never on a schedule. Peers pick it
    /// up on their next bundle fetch; sends to the old id fail and retry.
    @discardableResult
    public func rotateMailbox() async throws -> String {
        struct Response: Decodable { let mailboxId: String }
        let r: Response = try await request(
            "POST", "v1/devices/me/mailbox/rotate", body: nil as [String: String]?
        )
        return r.mailboxId
    }

    /// A sealed-sender delivery certificate binding this account and device to
    /// its identity key, valid 7 days. Cache it and refresh before `expiresAt`.
    /// Throws `.http(503, ...)` if the relay has sealed sender disabled.
    public func deliveryCertificate() async throws -> (certificate: Data, expiresAt: Int64) {
        struct Response: Decodable { let certificate: String; let expiresAt: Int64 }
        let r: Response = try await request("GET", "v1/certificate/delivery", body: nil as [String: String]?)
        guard let data = Data(base64Encoded: r.certificate) else {
            throw RelayAPIError.malformedResponse
        }
        return (data, r.expiresAt)
    }

    /// Delivers a sealed-sender message to one device via the unauthenticated
    /// endpoint over the anonymous session, so the relay never learns the sender.
    /// `content` is the blob from `CryptoEngine.sealedEncrypt`; `accessKey` is the
    /// recipient's 32-byte key from their bundle. No client clock is sent.
    /// Returns the relay's receive time.
    public func sendSealed(
        mailboxId: String,
        type: MessageKind,
        content: Data,
        accessKey: Data,
        ephemeral: Bool,
        silent: Bool = false
    ) async throws -> Int64 {
        struct Req: Encodable {
            let mailboxId: String
            let type: Int
            let content: String
            let accessKey: String
            let ephemeral: Bool
            let silent: Bool
        }
        struct Response: Decodable { let serverTimestamp: Int64 }
        var request = makeRequest("POST", "v1/messages/sealed")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Req(
            mailboxId: mailboxId,
            type: Int(type.wireType.rawValue),
            content: content.base64EncodedString(),
            accessKey: accessKey.base64EncodedString(),
            ephemeral: ephemeral,
            silent: silent
        ))
        let (data, _) = try await sendWithToken(request)
        return try JSONDecoder().decode(Response.self, from: data).serverTimestamp
    }

    /// Source-compatible shim; `clientTimestamp` is ignored.
    @available(*, deprecated, message: "clientTimestamp is no longer sent; drop the argument")
    public func sendSealed(
        mailboxId: String,
        type: MessageKind,
        content: Data,
        accessKey: Data,
        ephemeral: Bool,
        silent: Bool = false,
        clientTimestamp: Int64
    ) async throws -> Int64 {
        try await sendSealed(mailboxId: mailboxId, type: type, content: content,
                             accessKey: accessKey, ephemeral: ephemeral, silent: silent)
    }

    /// Fetches queued envelopes over REST (HTTP/3), for when the TCP WebSocket
    /// can't connect. Doesn't dequeue; ack each with `ackMessage`. Follows
    /// `GET /v1/queue?limit=&cursor=` for at most `maxPages` pages per call.
    public func fetchQueue(pageSize: Int = 100, maxPages: Int = 10) async throws -> [IncomingEnvelope] {
        struct Response: Decodable {
            let envelopes: [String]
            let more: Bool?
            let cursor: String?
        }
        var all: [IncomingEnvelope] = []
        var cursor: String?
        for _ in 0..<max(1, maxPages) {
            var components = URLComponents()
            var items = [URLQueryItem(name: "limit", value: String(min(max(pageSize, 1), 100)))]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = items
            // URLComponents leaves "+" literal, which servers decode as a space. The
            // cursor may be base64, so encode it explicitly.
            let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            var request = makeRequest("GET", "v1/queue")
            if var urlComponents = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
                urlComponents.percentEncodedQuery = query
                request.url = urlComponents.url
            }
            let (data, _) = try await send(request, authenticated: true)
            let page = try JSONDecoder().decode(Response.self, from: data)
            all += page.envelopes.compactMap {
                Data(base64Encoded: $0).flatMap { IncomingEnvelope(serializedEnvelope: $0) }
            }
            guard page.more == true, let next = page.cursor, !next.isEmpty else { break }
            cursor = next
        }
        return all
    }

    /// Removes a delivered envelope from the queue; the REST form of the
    /// WebSocket ack.
    public func ackMessage(envelopeId: String) async throws {
        try await requestExpectingNoContent("POST", "v1/messages/ack", body: ["envelopeId": envelopeId])
    }

    public func setAPNSToken(_ token: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/apns", body: ["token": token])
    }

    public func setVoIPToken(_ token: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/voip", body: ["token": token])
    }

    /// Whether APNs pushes carry the encrypted envelope (`true`) or are a
    /// contentless wake (`false`, the relay's default; the app turns it on).
    public func setPushIncludeContent(_ include: Bool) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/me/push-content", body: ["includeContent": include])
    }

    /// The P-256 auth public key of a device on this account, used to verify
    /// nuke command signatures.
    public func deviceAuthKey(deviceId: UInt32) async throws -> Data {
        struct Response: Decodable { let authPublicKey: String }
        let r: Response = try await request("GET", "v1/devices/\(deviceId)/auth-key", body: nil as String?)
        guard let data = Data(base64Encoded: r.authPublicKey) else {
            throw RelayAPIError.malformedResponse
        }
        return data
    }

    /// Registers this device's auth key. Signed with the current key; only when
    /// the relay has no key for the device yet does this fall back to HTTP Basic.
    /// Rotating to a new key must be signed by the old one.
    public func setDeviceAuthorizationKey(_ publicKey: Data) async throws {
        do {
            try await requestExpectingNoContent(
                "PUT",
                "v1/devices/auth-key",
                body: DeviceAuthorizationKeyRequest(publicKey: publicKey.base64EncodedString())
            )
        } catch RelayAPIError.http(status: 401, _) where signer != nil {
            // Share the single Basic bootstrap with any signed request racing us, then
            // re-assert the key with a signature.
            guard let credentials else { throw RelayAPIError.http(status: 401, message: "no device credentials") }
            let client = self
            await AuthKeyBootstrapLedger.shared.runOnce(for: credentials) {
                _ = try? await client.bootstrapAuthKey(publicKey)
            }
            do {
                try await requestExpectingNoContent(
                    "PUT",
                    "v1/devices/auth-key",
                    body: DeviceAuthorizationKeyRequest(publicKey: publicKey.base64EncodedString())
                )
            } catch RelayAPIError.http(status: 401, _) {
                throw RelayAPIError.http(status: 401, message: "device authorization key rejected")
            }
        }
    }

    /// Called by the primary to register a linked device with the password the
    /// new device will use. Returns the new device id.
    public func addDevice(password: String, authorization: DeviceMutationAuthorization) async throws -> UInt32 {
        struct Response: Decodable { let deviceId: UInt32 }
        let r: Response = try await request(
            "POST",
            "v1/devices",
            body: AddDeviceRequest(password: password, deviceName: nil, auth: authorization)
        )
        return r.deviceId
    }

    // MARK: - Device linking

    /// New device: creates a provisioning session. Unauthenticated. Its
    /// `sessionId` and an ephemeral public key go in the QR the primary scans.
    public func createProvisioningSession() async throws -> ProvisioningSession {
        try await request("POST", "v1/provisioning-sessions", body: nil as String?, authenticated: false)
    }

    /// New device: polls for the primary's encrypted payload. Nil until it is
    /// provisioned (204); throws `.http(404)` once expired or consumed.
    public func fetchProvisioningBlob(sessionId: String) async throws -> Data? {
        let request = makeRequest("GET", "v1/provisioning-sessions/\(sessionId)")
        let (data, status) = try await send(request, authenticated: false)
        if status == 204 { return nil }
        struct Response: Decodable { let blob: String }
        guard let blob = Data(base64Encoded: try JSONDecoder().decode(Response.self, from: data).blob) else {
            throw RelayAPIError.malformedResponse
        }
        return blob
    }

    /// Primary: stores the encrypted provisioning payload for a session.
    public func storeProvisioningBlob(sessionId: String, blob: Data) async throws {
        try await requestExpectingNoContent(
            "PUT",
            "v1/provisioning-sessions/\(sessionId)",
            body: ["blob": blob.base64EncodedString()]
        )
    }

    /// Primary: creates the new device after scanning the QR. The password is
    /// bound into the mutation signature. Returns the new device id.
    public func linkDevice(password: String, deviceName: String? = nil, authorization: DeviceMutationAuthorization) async throws -> UInt32 {
        struct Response: Decodable { let deviceId: UInt32 }
        let r: Response = try await request(
            "POST",
            "v1/devices/link",
            body: AddDeviceRequest(password: password, deviceName: deviceName, auth: authorization)
        )
        return r.deviceId
    }

    public func deviceList() async throws -> LinkedDeviceList {
        try await request("GET", "v1/devices", body: nil as String?)
    }

    /// Time-limited TURN credentials (coturn REST format), or nil if TURN isn't
    /// configured. With `afterFailure`, the relay checks its TURN server and
    /// hands out the backup if it's down.
    public func fetchTurnCredentials(afterFailure: Bool = false) async throws -> TurnCredentials? {
        do {
            var request = makeRequest("GET", "v1/turn-credentials")
            if afterFailure { request.url?.append(queryItems: [URLQueryItem(name: "failed", value: "1")]) }
            let (data, _) = try await send(request, authenticated: true)
            let creds = try JSONDecoder().decode(TurnCredentials.self, from: data)
            return creds
        } catch RelayAPIError.http(status: 404, message: _) {
            return nil
        }
    }

    public func listDevices() async throws -> [LinkedDevice] {
        let list = try await deviceList()
        return list.devices
    }

    /// Removes a linked device. The primary (id 1) can't be removed.
    public func removeDevice(deviceId: UInt32, authorization: DeviceMutationAuthorization) async throws {
        try await requestExpectingNoContent(
            "DELETE",
            "v1/devices/\(deviceId)",
            body: DeviceMutationRequest(auth: authorization)
        )
    }

    /// Permanently deletes the account (`DELETE /v1/accounts/me`): devices,
    /// prekeys, queued envelopes, push tokens, directory entries and username.
    /// `appleAuthorizationCode`, a fresh Sign in with Apple code, lets the relay
    /// revoke the user's Apple token as Apple requires.
    public func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        var request = makeRequest("DELETE", "v1/accounts/me")
        if let appleAuthorizationCode {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["appleAuthorizationCode": appleAuthorizationCode])
        }
        _ = try await send(request, authenticated: true)
    }

    /// Reports an account for abuse (`POST /v1/reports`). `messages` is plaintext
    /// the user chose to forward; nothing else is sent. Throws `.http(429, ...)`
    /// at the daily cap.
    public func reportAccount(
        _ accountId: String,
        reason: ReportReason,
        details: String? = nil,
        messages: [String] = []
    ) async throws {
        struct ReportRequest: Encodable {
            let reportedAccount: String
            let reason: String
            let details: String?
            let messages: [String]?
        }
        let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await requestExpectingNoContent(
            "POST", "v1/reports",
            body: ReportRequest(
                reportedAccount: accountId,
                reason: reason.rawValue,
                details: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                messages: messages.isEmpty ? nil : messages
            )
        )
    }

    /// Posts a signed remote-wipe command. The server checks the signature shape
    /// and relays it; each device verifies the signature before wiping.
    public func sendNukeCommand(commandId: String, creationTimeMs: Int64, initiatingDeviceId: UInt32, signature: Data) async throws {
        struct NukeRequest: Encodable {
            let commandId: String
            let creationTimeMs: Int64
            let initiatingDeviceId: UInt32
            let signature: String
        }
        try await requestExpectingNoContent(
            "POST", "v1/accounts/me/nuke",
            body: NukeRequest(
                commandId: commandId,
                creationTimeMs: creationTimeMs,
                initiatingDeviceId: initiatingDeviceId,
                signature: signature.base64EncodedString()
            )
        )
    }

    /// Rings the callee's devices via the unauthenticated `POST /v1/calls/ring`
    /// over the anonymous session, authorized like a sealed send:
    /// `destinationMailbox` is one of the callee's mailbox ids and `accessKey`
    /// their access key. The push carries only `callId`; the caller and call kind
    /// travel inside the encrypted offer. Throws `.http(403, ...)` for a stale
    /// mailbox or wrong key, indistinguishably.
    public func ringCall(destinationMailbox: String, accessKey: Data, callId: String) async throws {
        struct Req: Encodable {
            let destinationMailbox: String
            let accessKey: String
            let callId: String
        }
        var request = makeRequest("POST", "v1/calls/ring")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Req(
            destinationMailbox: destinationMailbox,
            accessKey: accessKey.base64EncodedString(),
            callId: callId
        ))
        _ = try await sendWithToken(request)
    }

    // MARK: - Prekeys

    /// Uploads a key publication. `replaceOneTimePreKeys` deletes the device's
    /// existing one-time pool first; use it when the local store is fresh or out
    /// of sync, so the relay can't serve an orphaned key. Top-ups append.
    public func uploadKeys(_ publication: PreKeyPublication, replaceOneTimePreKeys: Bool = false) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/keys", body: PublicationDTO(publication, replaceOneTimePreKeys: replaceOneTimePreKeys)
        )
    }

    public func oneTimePreKeyCount() async throws -> Int {
        try await preKeyCounts().ec
    }

    /// Remaining one-time EC and Kyber prekeys on the relay (Kyber is 0 on
    /// relays without a Kyber pool).
    public func preKeyCounts() async throws -> (ec: Int, kyber: Int) {
        struct Response: Decodable { let count: Int; let kyberCount: Int? }
        let response: Response = try await request(
            "GET", "v1/keys/count", body: nil as [String: String]?
        )
        return (response.count, response.kyberCount ?? 0)
    }

    /// Bundles for every device of the account. Consumes one-time prekeys.
    public func fetchPreKeyBundles(account: String) async throws -> [PeerPreKeyBundle] {
        try await fetchPreKeyBundlesWithAccessKey(account: account).bundles
    }

    /// Also returns the account's sealed-sender access key, if published, so the
    /// caller can use the unauthenticated path without another round trip.
    public func fetchPreKeyBundlesWithAccessKey(
        account: String
    ) async throws -> (bundles: [PeerPreKeyBundle], accessKey: Data?) {
        struct Response: Decodable { let devices: [BundleDTO]; let accessKey: String? }
        let response: Response = try await request(
            "GET", "v1/keys/\(account)", body: nil as [String: String]?
        )
        let bundles = try response.devices.map { try $0.model() }
        let accessKey = response.accessKey.flatMap { Data(base64Encoded: $0) }
        return (bundles, accessKey)
    }

    /// Anonymous variant, authorized by the account's access key instead of our
    /// signature so the relay can't record who fetches whose keys. 403 means a
    /// wrong or rotated key.
    public func fetchPreKeyBundlesSealed(account: String, accessKey: Data) async throws -> [PeerPreKeyBundle] {
        struct Response: Decodable { let devices: [BundleDTO] }
        var request = makeRequest("GET", "v1/keys/\(account)/sealed")
        request.setValue(accessKey.base64EncodedString(), forHTTPHeaderField: "Relay-Access-Key")
        let (data, _) = try await sendWithToken(request)
        return try JSONDecoder().decode(Response.self, from: data).devices.map { try $0.model() }
    }

    // MARK: - Group invites

    /// Uploads an encrypted group-invite blob and returns the token and expiry.
    /// The decryption key travels in the URL fragment.
    public func createEncryptedGroupInvite(blob: Data) async throws -> (token: String, expiresAt: Int64) {
        struct Req: Encodable { let blob: String }
        struct Response: Decodable { let token: String; let expiresAt: Int64 }
        let r: Response = try await request(
            "POST", "v1/group-invites", body: Req(blob: blob.base64EncodedString())
        )
        return (r.token, r.expiresAt)
    }

    /// Fetches the encrypted blob for an invite token. Anonymous; the token is
    /// the capability.
    public func claimEncryptedGroupInvite(token: String) async throws -> Data {
        struct Response: Decodable { let blob: String }
        let r: Response = try await request(
            "POST", "v1/group-invites/claim", body: TokenRequest(token: token), authenticated: false
        )
        guard let blob = Data(base64Encoded: r.blob) else { throw RelayAPIError.malformedResponse }
        return blob
    }

    // MARK: - Attachments

    /// Reserves a blob id (authenticated), then uploads the ciphertext to it
    /// anonymously. The id is the capability and can be written once. Returns the
    /// id for the AttachmentPointer.
    public func uploadAttachment(_ ciphertext: Data) async throws -> String {
        struct Response: Decodable { let id: String }
        let created: Response = try await request(
            "POST", "v1/attachments", body: nil as [String: String]?
        )
        var request = makeRequest("PUT", "v1/attachments/\(created.id)")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = ciphertext
        _ = try await send(request, authenticated: false)
        return created.id
    }

    /// Largest attachment ciphertext accepted: the relay's 95 MiB Relay
    /// Supporter upload cap plus overhead, so a misbehaving relay can't make us
    /// buffer an unbounded download.
    public static let maxAttachmentDownloadBytes = 96 << 20

    public func downloadAttachment(id: String) async throws -> Data {
        var request = makeRequest("GET", "v1/attachments/\(id)")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (data, response) = try await fetch(request, on: anonymousSession)
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RelayAPIError.http(status: http.statusCode, message: "")
        }
        guard data.count <= Self.maxAttachmentDownloadBytes else { throw RelayAPIError.malformedResponse }
        return data
    }


    // MARK: - Encrypted profiles

    /// PUT /v1/profiles/{id}: stores our encrypted profile. Anonymous; the write
    /// secret proves it's ours and a send token pays for it.
    public func putProfile(id: Data, writeSecret: Data, blob: Data) async throws {
        var request = makeRequest("PUT", "v1/profiles/\(Self.base64URL(id))")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.base64URL(writeSecret), forHTTPHeaderField: "Relay-Profile-Write")
        request.httpBody = blob
        _ = try await sendWithToken(request)
    }

    /// DELETE /v1/profiles/{id}: removes a profile we no longer use.
    public func deleteProfile(id: Data, writeSecret: Data) async throws {
        var request = makeRequest("DELETE", "v1/profiles/\(Self.base64URL(id))")
        request.setValue(Self.base64URL(writeSecret), forHTTPHeaderField: "Relay-Profile-Write")
        _ = try await send(request, authenticated: false)
    }

    public enum ProfileFetch: Sendable {
        case changed(blob: Data, etag: String?)
        case unchanged
        case missing
    }

    /// GET /v1/profiles/{id}: a contact's encrypted profile, anonymously.
    /// With the ETag from last time, an unchanged profile isn't downloaded.
    public func fetchProfile(id: Data, etag: String?) async throws -> ProfileFetch {
        var request = makeRequest("GET", "v1/profiles/\(Self.base64URL(id))")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await fetch(request, on: anonymousSession)
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.malformedResponse }
        switch http.statusCode {
        case 304: return .unchanged
        case 404: return .missing
        case 200:
            guard data.count <= 128 << 10 else { throw RelayAPIError.malformedResponse }
            return .changed(blob: data, etag: http.value(forHTTPHeaderField: "ETag"))
        default:
            throw RelayAPIError.http(status: http.statusCode, message: "")
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }


    // MARK: - Request plumbing

    private func makeRequest(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.assumesHTTP3Capable = true
        return request
    }

    /// Sends `request`. Anonymous requests carry no credentials and use the
    /// separate session. Authenticated ones are signed, or use HTTP Basic only
    /// when no signer is configured. A 401 because the relay has no auth key for
    /// the device yet triggers a one-time bootstrap and one re-signed retry.
    private func send(_ request: URLRequest, authenticated: Bool) async throws -> (Data, Int) {
        do {
            return try await sendOnce(request, authenticated: authenticated)
        } catch let needed as StepUpRequired {
            guard let stepUp, await stepUp() else { throw needed }
            return try await sendOnce(request, authenticated: authenticated)
        }
    }

    /// An anonymous capability request, with a send token when there is one.
    /// A token the relay refuses (401: used, or from a day it no longer
    /// takes) is replaced once.
    private func sendWithToken(_ request: URLRequest) async throws -> (Data, Int) {
        guard let sendToken else { return try await send(request, authenticated: false) }
        var tokened = request
        tokened.setValue(await sendToken(), forHTTPHeaderField: "Relay-Token")
        do {
            return try await send(tokened, authenticated: false)
        } catch RelayAPIError.http(status: 401, _) where tokened.value(forHTTPHeaderField: "Relay-Token") != nil {
            tokened.setValue(await sendToken(), forHTTPHeaderField: "Relay-Token")
            return try await send(tokened, authenticated: false)
        }
    }

    /// POST /v1/send-tokens: has the relay evaluate blinded send tokens for
    /// `day` (its UTC day number). When the relay's day is another, it answers
    /// with that day and no tokens, and the caller blinds again.
    public func sendTokens(day: Int64, blinded: [Data]) async throws -> (day: Int64, tokens: [(evaluated: Data, proof: Data)]) {
        struct Req: Encodable { let day: Int64; let blinded: [Data] }
        struct Token: Decodable { let evaluated: Data; let proof: Data }
        struct Response: Decodable { let day: Int64; let tokens: [Token] }
        let r: Response = try await request("POST", "v1/send-tokens", body: Req(day: day, blinded: blinded))
        return (r.day, r.tokens.map { ($0.evaluated, $0.proof) })
    }

    private func sendOnce(_ request: URLRequest, authenticated: Bool) async throws -> (Data, Int) {
        guard authenticated else {
            var anonymous = request
            anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
            return try await perform(anonymous, on: anonymousSession)
        }
        guard let credentials else {
            throw RelayAPIError.http(status: 401, message: "no device credentials")
        }
        guard let signer else {
            var basic = request
            basic.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
            return try await perform(basic, on: session)
        }
        do {
            return try await perform(try signed(request, credentials: credentials, signer: signer), on: session)
        } catch RelayAPIError.http(status: 425, _) {
            // Signed before the relay restarted: a fresh signature goes through.
            return try await perform(try signed(request, credentials: credentials, signer: signer), on: session)
        } catch RelayAPIError.http(status: 401, let message) {
            // The relay may have no key for this device. Register it via Basic at most
            // once per process, then retry once with a fresh signature; even if our
            // upload was refused, another path may have registered the key.
            guard request.url?.path(percentEncoded: false).hasSuffix("/v1/devices/auth-key") == false,
                  let publicKey = signer.relayAuthPublicKey()
            else { throw RelayAPIError.http(status: 401, message: message) }
            let client = self
            await AuthKeyBootstrapLedger.shared.runOnce(for: credentials) {
                _ = try? await client.bootstrapAuthKey(publicKey)
            }
            return try await perform(try signed(request, credentials: credentials, signer: signer), on: session)
        }
    }

    private func signed(_ request: URLRequest, credentials: RelayCredentials,
                        signer: any RelayRequestSigner) throws -> URLRequest {
        var request = request
        guard RelaySignature.sign(&request, credentials: credentials, signer: signer) else {
            throw RelayAPIError.http(status: 401, message: "request signing unavailable")
        }
        return request
    }

    /// Registers `publicKey` as the auth key over HTTP Basic, the only Basic
    /// request the client makes; the relay accepts it only while the device has
    /// no key. Returns false if refused.
    private func bootstrapAuthKey(_ publicKey: Data) async throws -> Bool {
        guard let credentials else { return false }
        var request = makeRequest("PUT", "v1/devices/auth-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeviceAuthorizationKeyRequest(publicKey: publicKey.base64EncodedString()))
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        do {
            _ = try await perform(request, on: session)
            return true
        } catch RelayAPIError.http(status: 401, _) {
            return false
        }
    }

    /// `answered`: a response already fetched, to check without sending again.
    private func perform(_ request: URLRequest, on session: URLSession,
                         answered: (Data, URLResponse)? = nil) async throws -> (Data, Int) {
        let (data, response) = if let answered { answered } else { try await fetch(request, on: session) }
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            if http.statusCode == 403 {
                struct ForbiddenBody: Decodable { let stepUp: StepUpRequired }
                if let forbidden = try? JSONDecoder().decode(ForbiddenBody.self, from: data) { throw forbidden.stepUp }
            }
            if http.statusCode == 423 {
                struct LockedBody: Decodable { let twoStep: TwoStepRequired }
                if let locked = try? JSONDecoder().decode(LockedBody.self, from: data) { throw locked.twoStep }
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw RelayAPIError.rateLimited(message: message, retryAfter: retryAfter)
            }
            throw RelayAPIError.http(status: http.statusCode, message: message)
        }
        return (data, http.statusCode)
    }

    /// Sends a request for the relay through the encrypted tunnel
    /// (RelayTunnel), so Cloudflare sees neither its path nor its headers. Only
    /// bodies over RelayTunnel.maxBody, and responses relayd says are too large
    /// to carry, go direct.
    private func fetch(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        guard let url = request.url, let primary = baseURL.host(), url.host() == primary else {
            return try await session.data(for: request)
        }
        guard (request.httpBody?.count ?? 0) <= RelayTunnel.maxBody else {
            return try await route(request, on: session, primary: primary)
        }
        let (message, pending) = try RelayTunnel.seal(request)
        var outer = URLRequest(url: baseURL.appending(path: "v1/t"), timeoutInterval: request.timeoutInterval)
        outer.httpMethod = "POST"
        outer.assumesHTTP3Capable = request.assumesHTTP3Capable
        outer.setValue("message/ohttp-req", forHTTPHeaderField: "Content-Type")
        outer.httpBody = message
        let (data, response) = try await route(outer, on: session, primary: primary)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RelayAPIError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "")
        }
        let inner: RelayTunnel.Response
        do { inner = try pending.open(data) } catch { throw RelayAPIError.malformedResponse }
        if inner.tooLarge { return try await route(request, on: session, primary: primary) }
        guard let answer = HTTPURLResponse(url: url, statusCode: inner.status, httpVersion: nil,
                                           headerFields: inner.headers)
        else { throw RelayAPIError.malformedResponse }
        return (inner.body, answer)
    }

    /// Sends to the relay's current address (the main one or a backup; see
    /// RelayFallback). If that address can't be reached at all, the request
    /// never arrived, so it's sent once more to whichever address answers.
    private func route(_ request: URLRequest, on session: URLSession, primary: String) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw RelayAPIError.malformedResponse }
        var routed = request
        routed.url = RelayFallback.route(url)
        do {
            #if DEBUG
            if RelayFallback.simulatesBlocked(routed.url?.host()) { throw URLError(.cannotFindHost) }
            #endif
            return try await session.data(for: routed)
        } catch where RelayProxy.active == nil && RelayFallback.suggestsBlock(error) {
            let failed = routed.url?.host() ?? primary
            let host = await RelayFallback.failover(primary: primary, failedHost: failed, session: session)
            // A timeout may have reached the relay: switch for later requests, don't resend.
            guard RelayFallback.isUnreachable(error), let host,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { throw error }
            components.host = host
            routed.url = components.url
            return try await session.data(for: routed)
        }
    }

    // MARK: Key transparency (docs/KEY_TRANSPARENCY.md)

    /// GET /v1/kt/lookup/{account}: proof of an account's current identity keys.
    /// With the account's access key the lookup is anonymous (the `/sealed`
    /// route, like the sealed bundle fetch), so the relay can't record who
    /// checks whose keys; 403 means a wrong or rotated key. Without one it's
    /// signed, which names us to the relay.
    public func keyTransparencyLookup(account: String, since: UInt32 = 0, accessKey: Data? = nil) async throws -> KeyTransparency.Lookup {
        var request = makeRequest("GET", accessKey == nil ? "v1/kt/lookup/\(account)" : "v1/kt/lookup/\(account)/sealed")
        if since > 0 { request.url?.append(queryItems: [URLQueryItem(name: "since", value: String(since))]) }
        let data: Data
        if let accessKey {
            request.setValue(accessKey.base64EncodedString(), forHTTPHeaderField: "Relay-Access-Key")
            (data, _) = try await sendWithToken(request)
        } else {
            (data, _) = try await send(request, authenticated: true)
        }
        return try JSONDecoder().decode(KeyTransparency.Lookup.self, from: data)
    }

    /// GET /v1/kt/consistency: proof the log at `to` extends the log at `from`.
    public func keyTransparencyConsistency(from: UInt64, to: UInt64) async throws -> [Data] {
        struct Response: Decodable { let proof: [Data] }
        var request = makeRequest("GET", "v1/kt/consistency")
        request.url?.append(queryItems: [URLQueryItem(name: "from", value: String(from)),
                                         URLQueryItem(name: "to", value: String(to))])
        let (data, _) = try await send(request, authenticated: false)
        return try JSONDecoder().decode(Response.self, from: data).proof
    }

    /// GET /v1/kt/monitor: this account's whole key history.
    public func keyTransparencyMonitor() async throws -> (versions: [KeyTransparency.Version], latest: KeyTransparency.Lookup) {
        struct Response: Decodable { let versions: [KeyTransparency.Version]; let latest: KeyTransparency.Lookup }
        let r: Response = try await request("GET", "v1/kt/monitor", body: nil as String?)
        return (r.versions, r.latest)
    }

    /// GET /v1/fallbacks: the backup addresses, saved for when the main one is blocked.
    public func refreshFallbackHosts() async throws {
        struct Response: Decodable { let hosts: [String] }
        let response: Response = try await request("GET", "v1/fallbacks", body: nil as String?)
        RelayFallback.save(hosts: response.hosts)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: String, body: Body?, authenticated: Bool = true
    ) async throws -> Response {
        var request = makeRequest(method, path)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, _) = try await send(request, authenticated: authenticated)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func requestExpectingNoContent<Body: Encodable>(
        _ method: String, _ path: String, body: Body, authenticated: Bool = true
    ) async throws {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await send(request, authenticated: authenticated)
    }
}

// MARK: - Passkeys

/// A passkey on the account, as listed by `GET /v1/passkeys`.
public struct PasskeySummary: Decodable, Sendable, Identifiable, Hashable {
    /// Base64url credential id.
    public let id: String
    public let name: String
    /// Milliseconds since 1970, rounded to the day by the relay.
    public let createdAt: Int64
}

/// Server challenge for adding a passkey.
public struct PasskeyRegistrationOptions: Sendable {
    public let challenge: Data
    public let userId: Data
    public let userName: String
    public let excludeCredentialIds: [Data]
}

extension RelayAPIClient {
    public func passkeyRegistrationOptions() async throws -> PasskeyRegistrationOptions {
        struct Response: Decodable {
            let challenge: String
            let userId: String
            let userName: String
            let excludeCredentialIds: [String]?
        }
        let r: Response = try await request("POST", "v1/passkeys/register/options", body: [String: String]())
        guard let challenge = Data(base64URL: r.challenge), let userId = Data(base64URL: r.userId) else {
            throw RelayAPIError.malformedResponse
        }
        return PasskeyRegistrationOptions(
            challenge: challenge, userId: userId, userName: r.userName,
            excludeCredentialIds: (r.excludeCredentialIds ?? []).compactMap { Data(base64URL: $0) }
        )
    }

    /// Stores a newly created passkey (`POST /v1/passkeys/register`).
    public func registerPasskey(
        credentialId: Data, clientDataJSON: Data, attestationObject: Data, name: String
    ) async throws {
        try await requestExpectingNoContent("POST", "v1/passkeys/register", body: [
            "credentialId": credentialId.base64URLEncoded,
            "clientDataJSON": clientDataJSON.base64URLEncoded,
            "attestationObject": attestationObject.base64URLEncoded,
            "name": name,
        ])
    }

    public func passkeys() async throws -> [PasskeySummary] {
        struct Response: Decodable { let passkeys: [PasskeySummary] }
        let r: Response = try await request("GET", "v1/passkeys", body: Optional<[String: String]>.none)
        return r.passkeys
    }

    public func deletePasskey(id: String) async throws {
        _ = try await send(makeRequest("DELETE", "v1/passkeys/\(id)"), authenticated: true)
    }

    /// Challenge for a passkey sign-in (`POST /v1/passkeys/login/options`).
    public func passkeyLoginOptions() async throws -> (challenge: Data, sessionId: String) {
        struct Response: Decodable { let challenge: String; let sessionId: String }
        let r: Response = try await request(
            "POST", "v1/passkeys/login/options", body: [String: String](), authenticated: false
        )
        guard let challenge = Data(base64URL: r.challenge) else { throw RelayAPIError.malformedResponse }
        return (challenge, r.sessionId)
    }

    /// Signs in with a passkey assertion and provisions a new device. A
    /// verified passkey satisfies registration lock, so no account password.
    public func signInWithPasskey(
        sessionId: String, credentialId: Data, clientDataJSON: Data, authenticatorData: Data,
        signature: Data, userHandle: Data, devicePassword: String
    ) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable {
            let accountId: String
            let deviceId: UInt32
            let username: String
        }
        let r: Response = try await request("POST", "v1/passkeys/login", body: [
            "sessionId": sessionId,
            "credentialId": credentialId.base64URLEncoded,
            "clientDataJSON": clientDataJSON.base64URLEncoded,
            "authenticatorData": authenticatorData.base64URLEncoded,
            "signature": signature.base64URLEncoded,
            "userHandle": userHandle.base64URLEncoded,
            "password": devicePassword,
        ], authenticated: false)
        return (RelayCredentials(accountId: r.accountId, deviceId: r.deviceId, password: devicePassword), r.username)
    }
}

/// Which ways an account can sign in (`GET /v1/accounts/me/sign-in-methods`).
public struct SignInMethods: Decodable, Sendable, Equatable {
    public let email: Bool
    public let passkeys: Int
    public let accountPassword: Bool
    public let recoveryKey: Bool
    /// The account password was stored by an older build and can't be used
    /// to sign in until it's entered again on a signed-in device.
    public let accountPasswordNeedsUpdate: Bool
    /// A verified phone number, which signs in by text code.
    public let phone: Bool
    /// The first two-step method: "" (off), "totp", "passkey", "pin" or "recovery".
    public let twoStep: String
    /// Every two-step method on (older relays send only `twoStep`).
    public let twoStepMethods: [TwoStepRequired.Method]

    public var twoStepMethod: TwoStepRequired.Method? { TwoStepRequired.Method(rawValue: twoStep) }

    enum CodingKeys: String, CodingKey { case email, passkeys, accountPassword, recoveryKey, accountPasswordNeedsUpdate, phone, twoStep, twoStepMethods }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(Bool.self, forKey: .email)
        passkeys = try c.decode(Int.self, forKey: .passkeys)
        accountPassword = try c.decode(Bool.self, forKey: .accountPassword)
        recoveryKey = try c.decode(Bool.self, forKey: .recoveryKey)
        accountPasswordNeedsUpdate = try c.decodeIfPresent(Bool.self, forKey: .accountPasswordNeedsUpdate) ?? false
        phone = try c.decodeIfPresent(Bool.self, forKey: .phone) ?? false
        twoStep = try c.decodeIfPresent(String.self, forKey: .twoStep) ?? ""
        let listed = (try c.decodeIfPresent([String].self, forKey: .twoStepMethods) ?? [])
            .compactMap(TwoStepRequired.Method.init(rawValue:))
        twoStepMethods = listed.isEmpty ? [TwoStepRequired.Method(rawValue: twoStep)].compactMap { $0 } : listed
    }
}

/// A passkey sign-up challenge (`POST /v1/passkeys/signup/options`).
public struct PasskeySignupOptions: Sendable {
    public let sessionId: String
    public let challenge: Data
    public let userId: Data
    public let userName: String
}

extension RelayAPIClient {
    /// Starts an account with no email: a username and a passkey.
    /// Returns nil if the username is taken.
    public func passkeySignupOptions(username: String) async throws -> PasskeySignupOptions? {
        struct Response: Decodable { let sessionId: String; let challenge: String; let userId: String; let userName: String }
        do {
            let r: Response = try await request(
                "POST", "v1/passkeys/signup/options", body: ["username": username], authenticated: false
            )
            guard let challenge = Data(base64URL: r.challenge), let userId = Data(base64URL: r.userId) else {
                throw RelayAPIError.malformedResponse
            }
            return PasskeySignupOptions(sessionId: r.sessionId, challenge: challenge, userId: userId, userName: r.userName)
        } catch RelayAPIError.http(409, _) {
            return nil
        }
    }

    public func signUpWithPasskey(
        sessionId: String, credentialId: Data, clientDataJSON: Data, attestationObject: Data,
        name: String, devicePassword: String
    ) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable { let accountId: String; let deviceId: UInt32; let username: String }
        let r: Response = try await request("POST", "v1/passkeys/signup", body: [
            "sessionId": sessionId,
            "credentialId": credentialId.base64URLEncoded,
            "clientDataJSON": clientDataJSON.base64URLEncoded,
            "attestationObject": attestationObject.base64URLEncoded,
            "name": name,
            "password": devicePassword,
        ], authenticated: false)
        return (RelayCredentials(accountId: r.accountId, deviceId: r.deviceId, password: devicePassword), r.username)
    }

    public func signInMethods() async throws -> SignInMethods {
        try await request("GET", "v1/accounts/me/sign-in-methods", body: Optional<[String: String]>.none)
    }

    /// Challenge for confirming email removal with one of this account's passkeys.
    public func emailRemovalOptions() async throws -> (challenge: Data, credentialIds: [Data]) {
        struct Response: Decodable { let challenge: String; let credentialIds: [String] }
        let r: Response = try await request("POST", "v1/accounts/me/email/remove/options", body: [String: String]())
        guard let challenge = Data(base64URL: r.challenge) else { throw RelayAPIError.malformedResponse }
        return (challenge, r.credentialIds.compactMap { Data(base64URL: $0) })
    }

    /// Removes the account's email (and its sign-in record) after a passkey check.
    public func removeEmail(
        credentialId: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data
    ) async throws {
        try await requestExpectingNoContent("POST", "v1/accounts/me/email/remove", body: [
            "credentialId": credentialId.base64URLEncoded,
            "clientDataJSON": clientDataJSON.base64URLEncoded,
            "authenticatorData": authenticatorData.base64URLEncoded,
            "signature": signature.base64URLEncoded,
            "userHandle": userHandle.base64URLEncoded,
        ])
    }

    /// Registers a recovery key by its hash; the key itself never leaves the device.
    public func setRecoveryKeyHash(_ hash: Data) async throws {
        try await requestExpectingNoContent("PUT", "v1/accounts/me/recovery-key", body: ["hash": hash.base64URLEncoded])
    }

    /// Signs in with a recovery key, replacing the account's devices. Skips
    /// registration lock and email codes.
    /// `authKey` is derived from the key on the device (the app's
    /// RecoveryKey.authKey); the key itself is never sent.
    public func signInWithRecoveryKey(authKey: String, devicePassword: String) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable { let accountId: String; let deviceId: UInt32; let username: String }
        let r: Response = try await request("POST", "v1/accounts/recovery-key/signin", body: [
            "authKey": authKey, "password": devicePassword,
        ], authenticated: false)
        return (RelayCredentials(accountId: r.accountId, deviceId: r.deviceId, password: devicePassword), r.username)
    }
}

// MARK: - Two-step verification and phone sign-in

/// A `403` before a sensitive change: this device must answer the account's
/// second step first (`stepUpChallenge`, then `verifyStepUp`).
public struct StepUpRequired: Error, LocalizedError, Decodable, Sendable {
    public let method: String
    public var errorDescription: String? { "Confirm it's you with two-step verification to make this change." }
}

/// A second-step challenge for a signed-in device.
public struct StepUpChallenge: Sendable, Identifiable {
    public let ticket: String
    public let method: TwoStepRequired.Method?
    /// Every method on; an answer to any one passes.
    public let methods: [TwoStepRequired.Method]
    /// For a passkey step.
    public let challenge: Data?
    public let credentialIds: [Data]
    public var id: String { ticket }
}

/// What a phone sign-in came back with.
public enum PhoneSignInOutcome: Sendable {
    case signedIn(credentials: RelayCredentials, username: String)
    case twoStepRequired(TwoStepRequired)
    /// No account has the number; `signupTicket` creates one (15 minutes).
    case noAccount(signupTicket: String)
}

/// The answer to a two-step ticket.
public enum TwoStepAnswer: Sendable {
    case code(String)
    case pin(AccountPasswordProof)
    case passkey(credentialId: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data)
}

extension RelayAPIClient {
    private struct SignedInResponse: Decodable { let accountId: String; let deviceId: UInt32; let username: String }

    /// A single-use App Attest challenge (5 minutes).
    public func appAttestChallenge() async throws -> String {
        struct Response: Decodable { let challenge: String }
        let r: Response = try await request("POST", "v1/app-attest/challenge", body: [String: String](), authenticated: false)
        return r.challenge
    }

    /// Registers an attested App Attest key. 403 if Apple's chain doesn't verify.
    public func registerAppAttestKey(keyId: Data, attestation: Data, challenge: String) async throws {
        var request = makeRequest("POST", "v1/app-attest/keys")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "keyId": keyId.base64URLEncoded, "attestation": attestation.base64URLEncoded, "challenge": challenge,
        ])
        _ = try await send(request, authenticated: false)
    }

    /// Texts a sign-in code to `phone`, vouched for by an App Attest assertion
    /// (nil only against a development relay that skips App Attest).
    /// 412: the relay doesn't know the key (attest it again).
    public func startPhoneSignIn(phone: String, attest: (keyId: Data, assertion: Data, challenge: String)?) async throws {
        var request = makeRequest("POST", "v1/phone/start")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "phone": phone, "keyId": attest?.keyId.base64URLEncoded ?? "",
            "assertion": attest?.assertion.base64URLEncoded ?? "", "challenge": attest?.challenge ?? "",
        ])
        _ = try await send(request, authenticated: false)
    }

    /// Checks a texted code. Signing in replaces the account's devices.
    public func signInWithPhone(phone: String, code: String, devicePassword: String) async throws -> PhoneSignInOutcome {
        struct NoAccount: Decodable { let signupTicket: String }
        var request = makeRequest("POST", "v1/phone/signin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["phone": phone, "code": code, "password": devicePassword])
        // A 404 carries the signup ticket, which `perform` would drop.
        let (data, response) = try await fetch(request, on: anonymousSession)
        if (response as? HTTPURLResponse)?.statusCode == 404,
           let noAccount = try? JSONDecoder().decode(NoAccount.self, from: data) {
            return .noAccount(signupTicket: noAccount.signupTicket)
        }
        do {
            let (data, _) = try await perform(request, on: anonymousSession, answered: (data, response))
            let r = try JSONDecoder().decode(SignedInResponse.self, from: data)
            return .signedIn(credentials: RelayCredentials(accountId: r.accountId, deviceId: r.deviceId, password: devicePassword),
                             username: r.username)
        } catch let twoStep as TwoStepRequired {
            return .twoStepRequired(twoStep)
        }
    }

    /// Creates an account for a number `signInWithPhone` found no account for.
    /// 409: the username is taken (the ticket still works).
    public func signUpWithPhone(signupTicket: String, username: String, devicePassword: String, discoverable: Bool) async throws -> (credentials: RelayCredentials, username: String) {
        struct Body: Encodable { let signupTicket: String; let username: String; let password: String; let discoverable: Bool }
        let r: SignedInResponse = try await request("POST", "v1/phone/signup", body: Body(
            signupTicket: signupTicket, username: username, password: devicePassword, discoverable: discoverable
        ), authenticated: false)
        return (RelayCredentials(accountId: r.accountId, deviceId: r.deviceId, password: devicePassword), r.username)
    }

    /// The challenge for a passkey second step.
    public func twoStepPasskeyOptions(ticket: String) async throws -> (challenge: Data, credentialIds: [Data]) {
        struct Response: Decodable { let challenge: String; let credentialIds: [String] }
        let r: Response = try await request("POST", "v1/accounts/two-step/passkey-options", body: ["ticket": ticket], authenticated: false)
        guard let challenge = Data(base64URL: r.challenge) else { throw RelayAPIError.malformedResponse }
        return (challenge, r.credentialIds.compactMap { Data(base64URL: $0) })
    }

    /// Finishes a sign-in with its second step, replacing the account's devices.
    /// 401: wrong answer or expired ticket.
    public func completeTwoStep(ticket: String, answer: TwoStepAnswer, devicePassword: String) async throws -> (credentials: RelayCredentials, username: String) {
        var body: [String: String] = ["ticket": ticket, "password": devicePassword]
        switch answer {
        case .code(let code):
            body["code"] = code
        case .pin(let proof):
            proof.addFields(to: &body)
        case .passkey(let credentialId, let clientDataJSON, let authenticatorData, let signature, let userHandle):
            body["credentialId"] = credentialId.base64URLEncoded
            body["clientDataJSON"] = clientDataJSON.base64URLEncoded
            body["authenticatorData"] = authenticatorData.base64URLEncoded
            body["signature"] = signature.base64URLEncoded
            body["userHandle"] = userHandle.base64URLEncoded
        }
        let r: SignedInResponse = try await request("POST", "v1/accounts/two-step", body: body, authenticated: false)
        return (RelayCredentials(accountId: r.accountId, deviceId: r.deviceId, password: devicePassword), r.username)
    }

    /// Starts adding an authenticator app: its secret (base32) and otpauth URI.
    public func setUpAuthenticator() async throws -> (secret: String, uri: String) {
        struct Response: Decodable { let secret: String; let uri: String }
        let r: Response = try await request("POST", "v1/accounts/me/totp/setup", body: [String: String]())
        return (r.secret, r.uri)
    }

    /// Confirms the authenticator with a code from it; it's then on, alongside any other two-step methods.
    public func confirmAuthenticator(code: String) async throws {
        try await requestExpectingNoContent("POST", "v1/accounts/me/totp/confirm", body: ["code": code])
    }

    /// Sets the two-step method (nil turns it off). 409: the account lacks what it needs.
    public func setTwoStep(_ method: TwoStepRequired.Method?) async throws {
        try await requestExpectingNoContent("PUT", "v1/accounts/me/two-step", body: ["method": method?.rawValue ?? ""])
    }

    /// Turns one two-step method on or off, keeping the others (the
    /// authenticator is turned on with `confirmAuthenticator`). 409: the
    /// account lacks what it needs.
    public func setTwoStep(_ method: TwoStepRequired.Method, enabled: Bool) async throws {
        struct Body: Encodable { let method: String; let enabled: Bool }
        try await requestExpectingNoContent("PUT", "v1/accounts/me/two-step", body: Body(method: method.rawValue, enabled: enabled))
    }

    /// A challenge for this device to answer the account's second step; nil
    /// when the account has none.
    public func stepUpChallenge() async throws -> StepUpChallenge? {
        struct Response: Decodable {
            let ticket: String?
            let method: String
            let methods: [String]?
            let challenge: String?
            let credentialIds: [String]?
        }
        let r: Response = try await request("POST", "v1/accounts/me/two-step/challenge", body: [String: String]())
        guard !r.method.isEmpty, let ticket = r.ticket else { return nil }
        return StepUpChallenge(
            ticket: ticket, method: TwoStepRequired.Method(rawValue: r.method),
            methods: {
                let listed = (r.methods ?? []).compactMap(TwoStepRequired.Method.init(rawValue:))
                return listed.isEmpty ? [TwoStepRequired.Method(rawValue: r.method)].compactMap { $0 } : listed
            }(),
            challenge: r.challenge.flatMap { Data(base64URL: $0) },
            credentialIds: (r.credentialIds ?? []).compactMap { Data(base64URL: $0) }
        )
    }

    /// Answers a step-up challenge; this device may then make sensitive
    /// changes for 5 minutes. 401: wrong answer.
    public func verifyStepUp(ticket: String, answer: TwoStepAnswer) async throws {
        var body: [String: String] = ["ticket": ticket]
        switch answer {
        case .code(let code):
            body["code"] = code
        case .pin(let proof):
            proof.addFields(to: &body)
        case .passkey(let credentialId, let clientDataJSON, let authenticatorData, let signature, let userHandle):
            body["credentialId"] = credentialId.base64URLEncoded
            body["clientDataJSON"] = clientDataJSON.base64URLEncoded
            body["authenticatorData"] = authenticatorData.base64URLEncoded
            body["signature"] = signature.base64URLEncoded
            body["userHandle"] = userHandle.base64URLEncoded
        }
        try await requestExpectingNoContent("POST", "v1/accounts/me/two-step/verify", body: body)
    }

    /// Answers with the recovery key instead (its derived auth key).
    public func verifyStepUp(recoveryAuthKey: String) async throws {
        try await requestExpectingNoContent("POST", "v1/accounts/me/two-step/verify", body: ["recoveryAuthKey": recoveryAuthKey])
    }

    public func deleteAccountPassword() async throws {
        _ = try await send(makeRequest("DELETE", "v1/accounts/me/account-password"), authenticated: true)
    }
}

extension Data {
    public init?(base64URL string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Reports

/// Abuse-report categories accepted by `POST /v1/reports`.
public enum ReportReason: String, CaseIterable, Sendable, Identifiable {
    case spam
    case harassment
    case inappropriate
    case impersonation
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment"
        case .inappropriate: "Inappropriate content"
        case .impersonation: "Impersonation"
        case .other: "Other"
        }
    }
}

/// Time-limited TURN credentials in coturn REST format.
public struct TurnCredentials: Decodable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String
    /// Lifetime in seconds from issue.
    public let ttl: Int
    /// TURN servers, preferred first. When Relay's own TURN server is down or
    /// overloaded, a backup provider is listed first. Absent from older relays.
    public let iceServers: [IceServer]?

    public struct IceServer: Decodable, Sendable {
        public let urls: [String]
        public let username: String?
        public let credential: String?
    }
}

public struct LinkedDevice: Decodable, Sendable, Identifiable {
    public let deviceId: UInt32
    public let mailboxId: String?
    public let name: String?
    public let createdAt: Int64?
    public var id: UInt32 { deviceId }
}

public struct LinkedDeviceList: Decodable, Sendable {
    public let devices: [LinkedDevice]
    public let deviceListVersion: Int64
}

public struct DeviceMutationAuthorization: Encodable, Sendable {
    public let expectedVersion: Int64
    public let signerDeviceId: UInt32
    public let signature: String

    public init(expectedVersion: Int64, signerDeviceId: UInt32, signature: String) {
        self.expectedVersion = expectedVersion
        self.signerDeviceId = signerDeviceId
        self.signature = signature
    }
}

public struct ProvisioningSession: Decodable, Sendable {
    public let sessionId: String
    public let expiresAt: Int64
}

private struct AddDeviceRequest: Encodable {
    let password: String
    let deviceName: String?
    let auth: DeviceMutationAuthorization
}

private struct DeviceMutationRequest: Encodable {
    let auth: DeviceMutationAuthorization
}

private struct TokenRequest: Encodable {
    let token: String
}

private struct DeviceAuthorizationKeyRequest: Encodable {
    let publicKey: String
}

// MARK: - Wire DTOs

private struct SignedPreKeyDTO: Codable {
    let keyId: UInt32
    let publicKey: String
    let signature: String

    init(_ key: SignedPublicPreKey) {
        keyId = key.id
        publicKey = key.publicKey.base64EncodedString()
        signature = key.signature.base64EncodedString()
    }

    func model() throws -> SignedPublicPreKey {
        guard let publicKey = Data(base64Encoded: publicKey),
              let signature = Data(base64Encoded: signature)
        else { throw RelayAPIError.malformedResponse }
        return SignedPublicPreKey(id: keyId, publicKey: publicKey, signature: signature)
    }
}

private struct OneTimePreKeyDTO: Codable {
    let keyId: UInt32
    let publicKey: String

    init(_ key: PublicPreKey) {
        keyId = key.id
        publicKey = key.publicKey.base64EncodedString()
    }

    func model() throws -> PublicPreKey {
        guard let publicKey = Data(base64Encoded: publicKey) else {
            throw RelayAPIError.malformedResponse
        }
        return PublicPreKey(id: keyId, publicKey: publicKey)
    }
}

private struct PublicationDTO: Encodable {
    let registrationId: UInt32
    let identityKey: String
    let signedPreKey: SignedPreKeyDTO
    let kyberPreKey: SignedPreKeyDTO
    let oneTimePreKeys: [OneTimePreKeyDTO]
    let oneTimeKyberPreKeys: [SignedPreKeyDTO]
    let replaceOneTimePreKeys: Bool

    init(_ publication: PreKeyPublication, replaceOneTimePreKeys: Bool = false) {
        registrationId = publication.registrationId
        identityKey = publication.identityKey.base64EncodedString()
        signedPreKey = SignedPreKeyDTO(publication.signedPreKey)
        kyberPreKey = SignedPreKeyDTO(publication.kyberPreKey)
        oneTimePreKeys = publication.oneTimePreKeys.map(OneTimePreKeyDTO.init)
        oneTimeKyberPreKeys = publication.oneTimeKyberPreKeys.map(SignedPreKeyDTO.init)
        self.replaceOneTimePreKeys = replaceOneTimePreKeys
    }
}

private struct BundleDTO: Decodable {
    let deviceId: UInt32
    let mailboxId: String?
    let registrationId: UInt32
    let identityKey: String
    let signedPreKey: SignedPreKeyDTO
    let kyberPreKey: SignedPreKeyDTO
    let oneTimePreKey: OneTimePreKeyDTO?

    func model() throws -> PeerPreKeyBundle {
        guard let identity = Data(base64Encoded: identityKey) else {
            throw RelayAPIError.malformedResponse
        }
        return PeerPreKeyBundle(
            deviceId: deviceId,
            mailboxId: mailboxId,
            registrationId: registrationId,
            identityKey: identity,
            signedPreKey: try signedPreKey.model(),
            kyberPreKey: try kyberPreKey.model(),
            oneTimePreKey: try oneTimePreKey?.model()
        )
    }
}
