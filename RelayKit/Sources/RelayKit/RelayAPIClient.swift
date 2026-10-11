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
}

public struct RelayAPIClient: Sendable {
    public let baseURL: URL
    public let credentials: RelayCredentials?
    private let session: URLSession
    private let anonymousSession: URLSession
    private let signer: (any RelayRequestSigner)?

    /// - Parameters:
    ///   - session: transport for signed requests.
    ///   - anonymousSession: transport for unauthenticated requests. Pass
    ///     `RelayTLS.makeAnonymousSession(pins:)` when pinning.
    ///   - signer: the device auth key. Required once the device has registered
    ///     one, since the relay then refuses Basic.
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

    /// Creates an account and primary device; needs no credentials.
    /// `supabaseAccessToken` links the account to a Supabase user. The relay
    /// verifies it and stores the email, as a keyed token for recovery and
    /// discovery, only if Supabase reports it confirmed; a raw email is never
    /// accepted. A non-nil accountPassword enables POST /v1/accounts/recover.
    /// Throws `.http(409, ...)` if the username is taken or the sign-in identity
    /// already has an account.
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

    /// Forgot password: with a Supabase session from a recovery code, sets a new
    /// account password and provisions this device, replacing the account's
    /// other devices like any fresh sign-in.
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

    /// Sets the account password, used for email recovery and as the registration
    /// lock on new-device sign-ins (`PUT /v1/accounts/me/account-password`).
    public func setAccountPassword(_ password: String) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/account-password", body: ["accountPassword": password])
    }

    /// Opts in or out of email discovery in blinded discovery. Off by default
    /// (`PUT /v1/accounts/me/discoverability`).
    public func setEmailDiscoverable(_ discoverable: Bool) async throws {
        struct Body: Encodable { let email: Bool }
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/discoverability", body: Body(email: discoverable))
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
        let r: Response = try await request(
            "POST", "v1/messages/sealed",
            body: Req(
                mailboxId: mailboxId,
                type: Int(type.wireType.rawValue),
                content: content.base64EncodedString(),
                accessKey: accessKey.base64EncodedString(),
                ephemeral: ephemeral,
                silent: silent
            ),
            authenticated: false
        )
        return r.serverTimestamp
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
    /// contentless wake (`false`, the default).
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
        _ = try await send(request, authenticated: false)
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
        let (data, _) = try await send(request, authenticated: false)
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

    /// Largest attachment ciphertext accepted: the relay's 25 MiB upload cap plus
    /// overhead, so a misbehaving relay can't make us buffer an unbounded download.
    public static let maxAttachmentDownloadBytes = 26 << 20

    public func downloadAttachment(id: String) async throws -> Data {
        var request = makeRequest("GET", "v1/attachments/\(id)")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        // Download to a temp file and check the size before loading it.
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

    /// Sends `request`. Anonymous requests carry no credentials and use the
    /// separate session. Authenticated ones are signed, or use HTTP Basic only
    /// when no signer is configured. A 401 because the relay has no auth key for
    /// the device yet triggers a one-time bootstrap and one re-signed retry.
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
    public func signInWithRecoveryKey(_ key: String, devicePassword: String) async throws -> (credentials: RelayCredentials, username: String) {
        struct Response: Decodable { let accountId: String; let deviceId: UInt32; let username: String }
        let r: Response = try await request("POST", "v1/accounts/recovery-key/signin", body: [
            "key": key, "password": devicePassword,
        ], authenticated: false)
        return (RelayCredentials(accountId: r.accountId, deviceId: r.deviceId, password: devicePassword), r.username)
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
