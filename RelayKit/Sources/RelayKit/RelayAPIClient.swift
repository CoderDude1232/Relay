//
//  RelayAPIClient.swift
//  RelayKit
//
//  The relay's JSON REST control plane: accounts, devices, prekeys.
//  Binary fields are standard base64, matching server/README.md exactly.
//
//  Two transports:
//   • `session` — authenticated calls, each signed with Relay-Sig v2 (see
//     RelaySigning.swift). HTTP Basic is used only to register a device's very
//     first auth key; there is no fallback to Basic after a failed signature.
//   • `anonymousSession` — a SEPARATE ephemeral URLSession for requests that
//     must not be linkable to the logged-in connection: sealed sends, call
//     rings, attachment GET/PUT, invite claims, sign-up/recovery. They never
//     carry credentials and never share a connection with `session`.
//

import CryptoCore
import Foundation
import Security

/// One resolved blinded-directory hit.
public struct DirectoryMatch: Sendable, Equatable {
    public let token: Data
    public let accountId: String
    public let username: String
    /// The account's sealed-sender access key, when the relay serves it.
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
    /// HTTP 429 from any endpoint (sealed sends, attachments, auth, discovery,
    /// reports, …). Distinct from `.http` so callers can back off rather than
    /// treat it as a failure; `retryAfter` is the Retry-After header, if sent.
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

/// Result of a Supabase social-login provisioning call.
public enum OAuthProvisionOutcome: Sendable {
    /// The user is signed in: fresh device credentials, the account's username,
    /// and whether the account was created by this call.
    case signedIn(credentials: RelayCredentials, username: String, created: Bool)
    /// No account exists yet for this user and no username was supplied — the
    /// caller should prompt for one and retry.
    case usernameRequired
    /// The account has an account password (registration lock): signing in on
    /// a new device, which replaces the account's devices, needs it. `incorrect`
    /// is true when one was supplied but didn't match.
    case accountPasswordRequired(incorrect: Bool)
}

public struct RelayAPIClient: Sendable {
    public let baseURL: URL
    public let credentials: RelayCredentials?
    private let session: URLSession
    private let anonymousSession: URLSession
    private let signer: (any RelayRequestSigner)?

    /// - Parameters:
    ///   - session: transport for authenticated (signed) requests.
    ///   - anonymousSession: transport for unauthenticated requests; defaults
    ///     to the process-wide ephemeral `RelayTLS.sharedAnonymousSession`.
    ///     Pass `RelayTLS.makeAnonymousSession(pins:)` when using pinned TLS.
    ///   - signer: the device auth key. Required for any account whose device
    ///     has registered an auth key (the relay refuses Basic after that).
    public init(baseURL: URL, credentials: RelayCredentials?,
                session: URLSession = RelayTLS.sharedSession,
                anonymousSession: URLSession = RelayTLS.sharedAnonymousSession,
                signer: (any RelayRequestSigner)? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        self.anonymousSession = anonymousSession
        self.signer = signer
    }

    // MARK: - Accounts

    /// Creates an account + primary device; needs no credentials.
    /// `supabaseAccessToken` (optional) links the account to a Supabase user:
    /// the relay verifies it server-side and stores the user's email (as its
    /// keyed token, for recovery and discovery) ONLY if Supabase reports it
    /// confirmed. A raw email is never accepted.
    /// Pass a non-nil accountPassword to enable recovery via POST /v1/accounts/recover.
    /// Throws `.http(409, …)` when the username is taken, or when the sign-in
    /// identity already belongs to an account (sign in instead).
    public func register(username: String, supabaseAccessToken: String? = nil, password: String,
                         accountPassword: String? = nil) async throws -> RelayCredentials {
        struct Response: Decodable {
            let accountId: String
            let deviceId: UInt32
        }
        var body: [String: String] = ["username": username, "password": password]
        if let supabaseAccessToken, !supabaseAccessToken.isEmpty { body["supabaseAccessToken"] = supabaseAccessToken }
        if let accountPassword, !accountPassword.isEmpty { body["accountPassword"] = accountPassword }
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

    /// Recovers an account by verifying the user's recovery password against the
    /// (verified) email on file and provisions a new device. Every failure —
    /// unknown email, no recovery password, wrong password — is the same
    /// `.http(401, …)`; repeated failures get `.http(429, …)`.
    /// App Review sign-in: a short review code signs this device in to one of
    /// the isolated demo accounts (no email or password).
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

    /// Replaces the blob if `baseVersion` is current (0 = none yet); returns the
    /// new version. 409 = another device wrote first.
    public func putAccountStorage(_ blob: Data, baseVersion: Int64) async throws -> Int64 {
        struct Body: Encodable { let blob: String; let baseVersion: Int64 }
        struct Response: Decodable { let version: Int64 }
        let r: Response = try await request(
            "PUT", "v1/accounts/me/storage",
            body: Body(blob: blob.base64EncodedString(), baseVersion: baseVersion)
        )
        return r.version
    }

    /// Whether this account is a demo account, and the other demo accounts.
    public func demoStatus() async throws -> (demo: Bool, peers: [String]) {
        struct Response: Decodable { let demo: Bool; let peers: [String] }
        let r: Response = try await request("GET", "v1/accounts/me/demo", body: nil as String?)
        return (r.demo, r.peers)
    }

    public func recoverAccount(email: String, accountPassword: String) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable {
            let accountId: String
            let username: String
            let deviceId: UInt32
            let devicePassword: String
        }
        let response: Response = try await request(
            "POST", "v1/accounts/recover",
            body: ["email": email, "accountPassword": accountPassword],
            authenticated: false
        )
        let creds = RelayCredentials(
            accountId: response.accountId,
            deviceId: response.deviceId,
            password: response.devicePassword
        )
        return (creds, response.username)
    }

    /// "Forgot password": with a Supabase session from a password-recovery code,
    /// sets a new account password and provisions this device (the account's
    /// other devices are replaced, like any fresh sign-in).
    public func resetPassword(supabaseAccessToken: String, newAccountPassword: String,
                              devicePassword: String) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable { let accountId: String; let username: String; let deviceId: UInt32 }
        let response: Response = try await request(
            "POST", "v1/accounts/password-reset",
            body: ["accessToken": supabaseAccessToken, "accountPassword": newAccountPassword,
                   "password": devicePassword],
            authenticated: false
        )
        return (RelayCredentials(accountId: response.accountId, deviceId: response.deviceId,
                                 password: devicePassword), response.username)
    }

    /// After a confirmed Supabase email change, re-keys the account's email
    /// token (`PUT /v1/accounts/me/email`).
    public func updateEmail(supabaseAccessToken: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/accounts/me/email",
                                            body: ["accessToken": supabaseAccessToken])
    }

    /// Signs a Supabase-authenticated user into their relay account (creating it
    /// on first use) and provisions a fresh device. The relay verifies the
    /// Supabase access token directly with Supabase, so this works on any device
    /// — the way back in for passwordless social-login accounts.
    ///
    /// `username` is required only when creating a brand-new account. If it is
    /// nil and no account exists yet, the server replies 404 and this returns
    /// `.usernameRequired` so the caller can prompt for one and retry.
    /// `devicePassword` is the client-chosen password for the new device.
    public func provisionOAuth(
        accessToken: String, username: String?, devicePassword: String, accountPassword: String? = nil
    ) async throws -> OAuthProvisionOutcome {
        struct Response: Decodable {
            let accountId: String
            let deviceId: UInt32
            let username: String
            let created: Bool
        }
        var body: [String: String] = ["accessToken": accessToken, "password": devicePassword]
        if let username, !username.isEmpty { body["username"] = username }
        if let accountPassword, !accountPassword.isEmpty { body["accountPassword"] = accountPassword }
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
        } catch RelayAPIError.http(423, let message) {
            return .accountPasswordRequired(incorrect: message.contains("incorrect"))
        }
    }

    /// Sets or changes the account password — used for email recovery and as
    /// the registration lock on new-device sign-ins (`PUT /v1/accounts/me/account-password`).
    public func setAccountPassword(_ password: String) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/account-password", body: ["accountPassword": password])
    }

    /// Opts in or out of being found by email in blinded discovery (off by
    /// default; `PUT /v1/accounts/me/discoverability`).
    public func setEmailDiscoverable(_ discoverable: Bool) async throws {
        struct Body: Encodable { let email: Bool }
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/discoverability", body: Body(email: discoverable))
    }

    /// Whether `name` is free to register (case-insensitive). Unauthenticated and
    /// rate-limited per IP; returns only a boolean, never an account id. Throws
    /// `.http(400, …)` for a syntactically invalid username.
    public func usernameAvailable(_ name: String) async throws -> Bool {
        struct Response: Decodable { let available: Bool }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let response: Response = try await request(
            "GET", "v1/usernames/\(encoded)/available", body: nil as [String: String]?,
            authenticated: false
        )
        return response.available
    }

    /// Blinded discovery, step 1: sends client-blinded ristretto elements and
    /// returns the server's OPRF evaluations (k·B). The relay never sees the
    /// underlying identifiers. Each element spends from a daily per-account budget.
    public func directoryEvaluate(blinded: [Data]) async throws -> [Data] {
        struct Req: Encodable { let blinded: [String] }
        struct Response: Decodable { let evaluated: [String] }
        let r: Response = try await request(
            "POST", "v1/directory/oprf",
            body: Req(blinded: blinded.map { $0.base64EncodedString() })
        )
        return r.evaluated.compactMap { Data(base64Encoded: $0) }
    }

    /// Blinded discovery, step 2: resolves derived OPRF tokens to accounts
    /// WITHOUT sending the tokens. Only each token's 16-bit bucket goes to the
    /// relay; matching (tag) and decryption (box) happen here. Unmatched tokens
    /// are simply absent from the result (non-users stay private).
    public func directoryResolve(tokens: [Data]) async throws -> [DirectoryMatch] {
        guard !tokens.isEmpty else { return [] }
        var byBucket: [UInt16: [Data]] = [:]
        for token in tokens {
            byBucket[DirectoryBuckets.bucket(for: token), default: []].append(token)
        }
        var matches: [DirectoryMatch] = []
        let buckets = Array(byBucket.keys)
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

    /// Raw bucket fetch (`POST /v1/directory/buckets`): every entry the relay
    /// holds in each requested bucket. Prefer `directoryResolve(tokens:)`.
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

    /// Changes the authenticated account's username. Throws RelayAPIError.http(409,…) if taken.
    public func updateUsername(_ username: String) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/username",
            body: ["username": username]
        )
    }

    /// Mints a single-use contact invite token for the authenticated account.
    /// Share it as a link; the first person to open it (and only them) resolves
    /// to this account, then the token is spent.
    public func createContactInvite() async throws -> (token: String, expiresAt: Int64) {
        struct Response: Decodable { let token: String; let expiresAt: Int64 }
        let r: Response = try await request("POST", "v1/contact-invites", body: nil as [String: String]?)
        return (r.token, r.expiresAt)
    }

    /// Consumes a contact invite token, returning the inviter's account id and
    /// username. Throws `RelayAPIError.http(404,…)` if invalid/expired/used.
    /// Anonymous: sent with no credentials over the unlinkable session, so the
    /// relay can't record who redeemed the invite.
    public func claimContactInvite(token: String) async throws -> (accountId: String, username: String) {
        struct Response: Decodable { let accountId: String; let username: String }
        let r: Response = try await request(
            "POST", "v1/contact-invites/claim", body: ["token": token], authenticated: false
        )
        return (r.accountId, r.username)
    }

    /// Uploads this account's sealed-sender access key (32 bytes). Senders present
    /// it on the unauthenticated delivery path; rotating it revokes old senders.
    public func setAccessKey(_ key: Data) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/access-key",
            body: ["accessKey": key.base64EncodedString()]
        )
    }

    /// Rotates this device's opaque mailbox id and returns the new one. Mailbox
    /// ids are otherwise stable — call this only on an explicit need (e.g. a
    /// suspected leak), never on a schedule. Peers pick it up on their next
    /// bundle fetch; sends to the old id fail-and-retry.
    @discardableResult
    public func rotateMailbox() async throws -> String {
        struct Response: Decodable { let mailboxId: String }
        let r: Response = try await request(
            "POST", "v1/devices/me/mailbox/rotate", body: nil as [String: String]?
        )
        return r.mailboxId
    }

    /// Fetches a sealed-sender delivery certificate for this device (binds the
    /// account/device to its identity key, 7-day expiry). Clients cache it and
    /// refresh before `expiresAt`. Throws `RelayAPIError.http(503,…)` if the relay
    /// hasn't enabled sealed sender.
    public func deliveryCertificate() async throws -> (certificate: Data, expiresAt: Int64) {
        struct Response: Decodable { let certificate: String; let expiresAt: Int64 }
        let r: Response = try await request("GET", "v1/certificate/delivery", body: nil as [String: String]?)
        guard let data = Data(base64Encoded: r.certificate) else {
            throw RelayAPIError.malformedResponse
        }
        return (data, r.expiresAt)
    }

    /// Delivers a sealed-sender message to one recipient device via the
    /// **unauthenticated** delivery endpoint, over the separate anonymous
    /// session — no Authorization header and no shared connection, so the relay
    /// never learns who sent it. `content` is the opaque sealed blob from
    /// `CryptoEngine.sealedEncrypt`; `accessKey` is the recipient's 32-byte
    /// access key (from their prekey bundle). No client clock goes on the wire
    /// (timestamps that matter live inside the encrypted content); returns the
    /// relay's receive time.
    public func sendSealed(
        mailboxId: String,
        type: MessageKind,
        content: Data,
        accessKey: Data,
        ephemeral: Bool
    ) async throws -> Int64 {
        struct Req: Encodable {
            let mailboxId: String
            let type: Int
            let content: String
            let accessKey: String
            let ephemeral: Bool
        }
        struct Response: Decodable { let serverTimestamp: Int64 }
        let r: Response = try await request(
            "POST", "v1/messages/sealed",
            body: Req(
                mailboxId: mailboxId,
                type: Int(type.wireType.rawValue),
                content: content.base64EncodedString(),
                accessKey: accessKey.base64EncodedString(),
                ephemeral: ephemeral
            ),
            authenticated: false
        )
        return r.serverTimestamp
    }

    /// Source-compatible shim: `clientTimestamp` is IGNORED and never sent.
    @available(*, deprecated, message: "clientTimestamp is no longer sent; drop the argument")
    public func sendSealed(
        mailboxId: String,
        type: MessageKind,
        content: Data,
        accessKey: Data,
        ephemeral: Bool,
        clientTimestamp: Int64
    ) async throws -> Int64 {
        try await sendSealed(mailboxId: mailboxId, type: type, content: content,
                             accessKey: accessKey, ephemeral: ephemeral)
    }

    /// Fetches this device's queued envelopes over the (HTTP/3) REST plane — a
    /// QUIC fallback for receiving when the TCP WebSocket can't connect. Does not
    /// dequeue; the caller acks each via `ackMessage`. Follows the paginated
    /// `GET /v1/queue?limit=&cursor=` until `more == false`, at most
    /// `maxPages` pages per call (anything left is picked up next time).
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
            // URLComponents leaves "+" literal, which servers decode as a space;
            // the cursor is opaque (may be base64), so encode it explicitly.
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

    /// Removes a delivered envelope from this device's queue (REST equivalent of
    /// the WebSocket ack).
    public func ackMessage(envelopeId: String) async throws {
        try await requestExpectingNoContent("POST", "v1/messages/ack", body: ["envelopeId": envelopeId])
    }

    public func setAPNSToken(_ token: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/apns", body: ["token": token])
    }

    public func setVoIPToken(_ token: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/voip", body: ["token": token])
    }

    /// Sets whether this device wants the encrypted envelope carried in its APNs
    /// payload (`true`) or a content-free wake (`false`, the private default).
    public func setPushIncludeContent(_ include: Bool) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/me/push-content", body: ["includeContent": include])
    }

    /// Fetches the ECDSA-P256 auth public key for a device in the same account.
    /// Used to independently verify nuke command signatures on the client.
    public func deviceAuthKey(deviceId: UInt32) async throws -> Data {
        struct Response: Decodable { let authPublicKey: String }
        let r: Response = try await request("GET", "v1/devices/\(deviceId)/auth-key", body: nil as String?)
        guard let data = Data(base64Encoded: r.authPublicKey) else {
            throw RelayAPIError.malformedResponse
        }
        return data
    }

    /// Registers (or re-asserts) this device's auth key. Signed with the current
    /// key; if the relay has no key for this device yet (first upload), this is
    /// the ONE request that falls back to HTTP Basic. Rotating to a different key
    /// must be signed by the old one — Basic is refused once a key exists.
    public func setDeviceAuthorizationKey(_ publicKey: Data) async throws {
        do {
            try await requestExpectingNoContent(
                "PUT",
                "v1/devices/auth-key",
                body: DeviceAuthorizationKeyRequest(publicKey: publicKey.base64EncodedString())
            )
        } catch RelayAPIError.http(status: 401, _) where signer != nil {
            // Share the one Basic bootstrap with any signed request racing us,
            // then re-assert the key signed: succeeds once the relay holds it.
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

    /// Registers a new linked device under the same account. The primary device
    /// calls this on behalf of the new device, supplying the password the new
    /// device will use. Returns the new device's id.
    public func addDevice(password: String, authorization: DeviceMutationAuthorization) async throws -> UInt32 {
        struct Response: Decodable { let deviceId: UInt32 }
        let r: Response = try await request(
            "POST",
            "v1/devices",
            body: AddDeviceRequest(password: password, deviceName: nil, auth: authorization)
        )
        return r.deviceId
    }

    public func createDeviceLinkInvitation(authorization: DeviceMutationAuthorization) async throws -> DeviceLinkInvitation {
        try await request(
            "POST",
            "v1/devices/link-invitations",
            body: DeviceMutationRequest(auth: authorization)
        )
    }

    public func claimDeviceLink(linkToken: String, verificationCode: String) async throws -> DeviceLinkClaim {
        try await request(
            "POST",
            "v1/devices/link-claims",
            body: DeviceLinkClaimRequest(linkToken: linkToken, verificationCode: verificationCode),
            authenticated: false
        )
    }

    // MARK: - Reversed device linking (shared account identity)

    /// New device: mints a blind provisioning session. Unauthenticated — the new
    /// device has no account yet. Its `sessionId` + a locally generated ephemeral
    /// public key go in the QR the primary scans.
    public func createProvisioningSession() async throws -> ProvisioningSession {
        try await request("POST", "v1/provisioning-sessions", body: nil as String?, authenticated: false)
    }

    /// New device: polls for the primary's encrypted payload. Returns nil while
    /// the primary hasn't provisioned yet (204); throws `.http(404)` once the
    /// session has expired or been consumed.
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

    /// Primary: deposits the encrypted provisioning payload for a session.
    public func storeProvisioningBlob(sessionId: String, blob: Data) async throws {
        try await requestExpectingNoContent(
            "PUT",
            "v1/provisioning-sessions/\(sessionId)",
            body: ["blob": blob.base64EncodedString()]
        )
    }

    /// Primary: creates the new device row after scanning the QR, supplying the
    /// password (bound into the mutation signature). Returns the new device id.
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

    /// Fetches time-limited TURN credentials (coturn REST API format).
    /// Returns nil if TURN is not configured on the server. `afterFailure`:
    /// the call's relay just failed — the relay checks its TURN server on the
    /// spot and hands out the backup if it's down.
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

    /// Lists all devices registered to this account.
    public func listDevices() async throws -> [LinkedDevice] {
        let list = try await deviceList()
        return list.devices
    }

    /// Removes a linked device. The primary device (id 1) cannot be removed.
    public func removeDevice(deviceId: UInt32, authorization: DeviceMutationAuthorization) async throws {
        try await requestExpectingNoContent(
            "DELETE",
            "v1/devices/\(deviceId)",
            body: DeviceMutationRequest(auth: authorization)
        )
    }

    /// Permanently deletes the authenticated account on the relay
    /// (`DELETE /v1/accounts/me`): every device, prekey, queued envelope,
    /// push token, directory entry and username is removed and live sockets
    /// are closed. The credentials are useless afterwards.
    /// Deletes the account. `appleAuthorizationCode` (a fresh Sign in with
    /// Apple code) lets the relay revoke the user's Apple token, as Apple requires.
    public func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        var request = makeRequest("DELETE", "v1/accounts/me")
        if let appleAuthorizationCode {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["appleAuthorizationCode": appleAuthorizationCode])
        }
        _ = try await send(request, authenticated: true)
    }

    /// Reports another account for abuse (`POST /v1/reports`). `messages` is
    /// plaintext the user explicitly chose to forward (empty by default);
    /// nothing else about the conversation is sent. Throws
    /// `RelayAPIError.http(429, …)` when the daily report cap is reached.
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

    /// Posts a signed remote-wipe command. The server validates signature shape and
    /// relays it to all devices; each device verifies the full signature before wiping.
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

    /// Rings the callee's devices (VoIP / FCM wake) for an incoming call via the
    /// **unauthenticated** `POST /v1/calls/ring`, over the anonymous session.
    /// Authorised exactly like a sealed send: `destinationMailbox` is any one of
    /// the callee's mailbox ids and `accessKey` their 32-byte sealed-sender access
    /// key (both from their prekey bundle). The relay rings all of the callee's
    /// devices with a push carrying ONLY `callId` — the caller's identity and the
    /// call kind travel solely inside the E2E-encrypted offer (a sealed message).
    /// Throws `.http(403, …)` for a stale mailbox or wrong key (indistinguishable).
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
        _ = try await send(request, authenticated: false)
    }

    // MARK: - Prekeys

    /// Uploads a key publication. `replaceOneTimePreKeys` tells the relay to
    /// delete this device's existing one-time pool before storing the batch —
    /// use it when the local store is fresh (install/restore) or a desync was
    /// detected, so the relay can't serve an orphaned one-time key. Ordinary
    /// top-ups leave it false and append.
    public func uploadKeys(_ publication: PreKeyPublication, replaceOneTimePreKeys: Bool = false) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/keys", body: PublicationDTO(publication, replaceOneTimePreKeys: replaceOneTimePreKeys)
        )
    }

    public func oneTimePreKeyCount() async throws -> Int {
        struct Response: Decodable { let count: Int }
        let response: Response = try await request(
            "GET", "v1/keys/count", body: nil as [String: String]?
        )
        return response.count
    }

    /// Fetches prekey bundles for every device of the account (consuming
    /// one-time prekeys server-side).
    public func fetchPreKeyBundles(account: String) async throws -> [PeerPreKeyBundle] {
        try await fetchPreKeyBundlesWithAccessKey(account: account).bundles
    }

    /// Like `fetchPreKeyBundles`, but also returns the account's sealed-sender
    /// access key (when it has published one) so the caller can address the
    /// recipient on the unauthenticated delivery path without a second round-trip.
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

    /// Anonymous variant: proves we may reach `account` with its sealed-sender
    /// access key instead of signing as ourselves, so the relay can't record who
    /// fetches whose keys. Sent with no credentials. 403 = wrong/rotated key.
    public func fetchPreKeyBundlesSealed(account: String, accessKey: Data) async throws -> [PeerPreKeyBundle] {
        struct Response: Decodable { let devices: [BundleDTO] }
        var request = makeRequest("GET", "v1/keys/\(account)/sealed")
        request.setValue(accessKey.base64EncodedString(), forHTTPHeaderField: "Relay-Access-Key")
        let (data, _) = try await send(request, authenticated: false)
        return try JSONDecoder().decode(Response.self, from: data).devices.map { try $0.model() }
    }

    // MARK: - Group invites (relay stores only opaque encrypted blobs; groups
    // themselves are fully client-managed and E2E — no server roster/name/admins)

    /// Uploads an opaque encrypted group-invite blob, returning the token + expiry.
    /// The relay only stores ciphertext; the decrypt key rides the URL fragment.
    public func createEncryptedGroupInvite(blob: Data) async throws -> (token: String, expiresAt: Int64) {
        struct Req: Encodable { let blob: String }
        struct Response: Decodable { let token: String; let expiresAt: Int64 }
        let r: Response = try await request(
            "POST", "v1/group-invites", body: Req(blob: blob.base64EncodedString())
        )
        return (r.token, r.expiresAt)
    }

    /// Fetches the opaque encrypted blob for an invite token (to decrypt client-side).
    /// Anonymous (no credentials, unlinkable session): the token is the capability.
    public func claimEncryptedGroupInvite(token: String) async throws -> Data {
        struct Response: Decodable { let blob: String }
        let r: Response = try await request(
            "POST", "v1/group-invites/claim", body: TokenRequest(token: token), authenticated: false
        )
        guard let blob = Data(base64Encoded: r.blob) else { throw RelayAPIError.malformedResponse }
        return blob
    }

    // MARK: - Attachments (opaque encrypted blobs)

    /// Allocates a blob id (authenticated — the relay reserves it), then uploads
    /// the encrypted bytes to it ANONYMOUSLY over the unlinkable session (the id
    /// is the capability; each id can be written once). Returns the id to put in
    /// the AttachmentPointer.
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

    /// Downloads an encrypted blob by id (raw ciphertext). Anonymous: no
    /// credentials, separate session — the download can't be tied to the account.
    /// Largest attachment ciphertext we'll accept: the relay's 25 MiB upload
    /// cap plus encryption overhead. A misbehaving relay can't make us buffer
    /// an arbitrarily large download.
    public static let maxAttachmentDownloadBytes = 26 << 20

    public func downloadAttachment(id: String) async throws -> Data {
        var request = makeRequest("GET", "v1/attachments/\(id)")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        // Stream to a temp file (ciphertext) rather than memory, and check the
        // size before loading it.
        let (file, response) = try await anonymousSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RelayAPIError.http(status: http.statusCode, message: "")
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard size <= Self.maxAttachmentDownloadBytes else { throw RelayAPIError.malformedResponse }
        return try Data(contentsOf: file)
    }

    // MARK: - Request plumbing

    private func makeRequest(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.assumesHTTP3Capable = true
        return request
    }

    /// Sends `request`. Anonymous requests go out with no credentials over the
    /// separate ephemeral session. Authenticated requests are signed (Relay-Sig
    /// v2) — or, only when no signer is configured, use HTTP Basic. A signed
    /// request rejected with 401 because the device has no auth key on the relay
    /// yet triggers a one-time bootstrap (register the key via Basic) and a
    /// single re-signed retry; there is no silent downgrade to Basic.
    private func send(_ request: URLRequest, authenticated: Bool) async throws -> (Data, Int) {
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
        } catch RelayAPIError.http(status: 401, let message) {
            // Bootstrap: the relay may hold no key for this device yet. Register
            // it via Basic at most once per process (concurrent callers share the
            // attempt), then retry once, freshly signed — even if our Basic upload
            // was refused, another path may have registered the key meanwhile.
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

    /// Registers `publicKey` as this device's auth key using HTTP Basic — the
    /// only Basic request the client ever makes, and the relay accepts it only
    /// while the device has no key. Returns false if the relay refused.
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

    private func perform(_ request: URLRequest, on session: URLSession) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw RelayAPIError.rateLimited(message: message, retryAfter: retryAfter)
            }
            throw RelayAPIError.http(status: http.statusCode, message: message)
        }
        return (data, http.statusCode)
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
        _ method: String, _ path: String, body: Body
    ) async throws {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await send(request, authenticated: true)
    }
}

// MARK: - Groups

/// A group's roster + state as returned by the relay.
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

/// Time-limited TURN credentials in coturn REST API format.
public struct TurnCredentials: Decodable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String
    /// Lifetime in seconds from issue time.
    public let ttl: Int
    /// Ordered TURN servers, preferred first. Present on newer relays: when
    /// Relay's own TURN server is down or overloaded this lists a backup
    /// provider first. Older relays send only the top-level fields.
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

public struct DeviceLinkInvitation: Decodable, Sendable {
    public let linkToken: String
    public let verificationCode: String
    public let expiresAt: Int64
}

public struct DeviceLinkClaim: Decodable, Sendable {
    public let accountId: String
    public let deviceId: UInt32
    public let password: String
    public let username: String?
}

private struct AddDeviceRequest: Encodable {
    let password: String
    let deviceName: String?
    let auth: DeviceMutationAuthorization
}

private struct DeviceMutationRequest: Encodable {
    let auth: DeviceMutationAuthorization
}

private struct DeviceLinkClaimRequest: Encodable {
    let linkToken: String
    let verificationCode: String
}

private struct TokenRequest: Encodable {
    let token: String
}

private struct DeviceAuthorizationKeyRequest: Encodable {
    let publicKey: String
}

// MARK: - Wire DTOs (base64 binary fields)

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
    let replaceOneTimePreKeys: Bool

    init(_ publication: PreKeyPublication, replaceOneTimePreKeys: Bool = false) {
        registrationId = publication.registrationId
        identityKey = publication.identityKey.base64EncodedString()
        signedPreKey = SignedPreKeyDTO(publication.signedPreKey)
        kyberPreKey = SignedPreKeyDTO(publication.kyberPreKey)
        oneTimePreKeys = publication.oneTimePreKeys.map(OneTimePreKeyDTO.init)
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
