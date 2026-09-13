//
//  RelayAPIClient.swift
//  RelayKit
//
//  The relay's JSON REST control plane: accounts, devices, prekeys.
//  Binary fields are standard base64, matching server/README.md exactly.
//

import CryptoCore
import Foundation

public enum RelayAPIError: Error, LocalizedError {
    case http(status: Int, message: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            return message.isEmpty ? "Server error (HTTP \(status))." : message
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
}

/// An account's connection state: online now, or when last seen (ms epoch).
public struct Presence: Decodable, Sendable, Equatable {
    public let online: Bool
    public let lastSeen: Int64
}

public struct RelayAPIClient: Sendable {
    public let baseURL: URL
    public let credentials: RelayCredentials?
    private let session: URLSession

    public init(baseURL: URL, credentials: RelayCredentials?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
    }

    // MARK: - Accounts

    /// Creates an account + primary device; needs no credentials.
    /// Pass a non-nil email to enable contact discovery and account recovery.
    /// Pass a non-nil accountPassword to enable recovery via POST /v1/accounts/recover.
    public func register(username: String, email: String?, password: String, accountPassword: String? = nil) async throws -> RelayCredentials {
        struct Response: Decodable {
            let accountId: String
            let deviceId: UInt32
        }
        var body: [String: String] = ["username": username, "password": password]
        if let email, !email.isEmpty { body["email"] = email }
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

    /// Recovers an account by verifying the user's recovery password against the email
    /// on file and provisions a new device. Returns the new device credentials and username.
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
        }
    }

    public func lookupAccount(username: String) async throws -> String {
        struct Response: Decodable { let accountId: String }
        let response: Response = try await request(
            "GET", "v1/accounts/by-username/\(username)", body: nil as [String: String]?,
            authenticated: false
        )
        return response.accountId
    }

    /// Looks up an account by email address. Returns (accountId, username) or throws if not found.
    public func lookupAccount(byEmail email: String) async throws -> (accountId: String, username: String) {
        struct Response: Decodable { let accountId: String; let username: String }
        let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
        let response: Response = try await request(
            "GET", "v1/accounts/by-email/\(encoded)", body: nil as String?
        )
        return (response.accountId, response.username)
    }

    /// Changes the authenticated account's username. Throws RelayAPIError.http(409,…) if taken.
    public func updateUsername(_ username: String) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/accounts/me/username",
            body: ["username": username]
        )
    }

    public func lookupUsername(account: String) async throws -> String {
        struct Response: Decodable { let username: String }
        let response: Response = try await request(
            "GET", "v1/accounts/\(account)", body: nil as [String: String]?
        )
        return response.username
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
    public func claimContactInvite(token: String) async throws -> (accountId: String, username: String) {
        struct Response: Decodable { let accountId: String; let username: String }
        let r: Response = try await request("POST", "v1/contact-invites/claim", body: ["token": token])
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
    /// **unauthenticated** delivery endpoint — no Authorization header, so the
    /// relay never learns who sent it. `content` is the opaque sealed blob from
    /// `CryptoEngine.sealedEncrypt`; `accessKey` is the recipient's 32-byte
    /// access key (from their prekey bundle). Returns the server timestamp.
    public func sendSealed(
        mailboxId: String,
        type: MessageKind,
        content: Data,
        accessKey: Data,
        ephemeral: Bool,
        clientTimestamp: Int64
    ) async throws -> Int64 {
        struct Req: Encodable {
            let mailboxId: String
            let type: Int
            let content: String
            let accessKey: String
            let ephemeral: Bool
            let clientTimestamp: Int64
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
                clientTimestamp: clientTimestamp
            ),
            authenticated: false
        )
        return r.serverTimestamp
    }

    /// An account's live connection state and last-seen time (ms since epoch).
    public func presence(account: String) async throws -> Presence {
        let response: Presence = try await request(
            "GET", "v1/presence/\(account)", body: nil as [String: String]?
        )
        return response
    }

    public func setAPNSToken(_ token: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/apns", body: ["token": token])
    }

    public func setVoIPToken(_ token: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/voip", body: ["token": token])
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

    public func setDeviceAuthorizationKey(_ publicKey: Data) async throws {
        try await requestExpectingNoContent(
            "PUT",
            "v1/devices/auth-key",
            body: DeviceAuthorizationKeyRequest(publicKey: publicKey.base64EncodedString())
        )
    }

    /// Registers a new linked device under the same account. The primary device
    /// calls this on behalf of the new device, supplying the password the new
    /// device will use. Returns the new device's id.
    public func addDevice(password: String, authorization: DeviceMutationAuthorization) async throws -> UInt32 {
        struct Response: Decodable { let deviceId: UInt32 }
        let r: Response = try await request(
            "POST",
            "v1/devices",
            body: AddDeviceRequest(password: password, auth: authorization)
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

    public func deviceList() async throws -> LinkedDeviceList {
        try await request("GET", "v1/devices", body: nil as String?)
    }

    /// Fetches time-limited TURN credentials (coturn REST API format).
    /// Returns nil if TURN is not configured on the server.
    public func fetchTurnCredentials() async throws -> TurnCredentials? {
        do {
            let creds: TurnCredentials = try await request("GET", "v1/turn-credentials", body: nil as String?)
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

    /// Triggers a VoIP push to wake `account`'s device(s) for an incoming call.
    public func triggerCallPush(
        account: String,
        callID: String,
        callerName: String,
        callerAccount: String,
        kind: String = "audio"
    ) async throws {
        try await requestExpectingNoContent(
            "POST", "v1/call/\(account)",
            body: [
                "callId": callID,
                "call_id": callID,
                "callerName": callerName,
                "caller_name": callerName,
                "callerAccount": callerAccount,
                "caller_account": callerAccount,
                "kind": kind,
                "call_kind": kind,
            ]
        )
    }

    // MARK: - Prekeys

    public func uploadKeys(_ publication: PreKeyPublication) async throws {
        try await requestExpectingNoContent(
            "PUT", "v1/keys", body: PublicationDTO(publication)
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

    // MARK: - Groups (server-stored roster)

    public func createGroup(name: String, members: [String]) async throws -> GroupState {
        try await request("POST", "v1/groups", body: CreateGroupRequest(name: name, members: members))
    }

    public func fetchGroup(id: String) async throws -> GroupState {
        try await request("GET", "v1/groups/\(id)", body: nil as String?)
    }

    public func addGroupMember(groupId: String, account: String) async throws -> GroupState {
        try await request("POST", "v1/groups/\(groupId)/members", body: AccountRequest(account: account))
    }

    public func removeGroupMember(groupId: String, account: String) async throws -> GroupState {
        try await request("DELETE", "v1/groups/\(groupId)/members/\(account)", body: nil as String?)
    }

    public func renameGroup(groupId: String, name: String) async throws -> GroupState {
        try await request("PUT", "v1/groups/\(groupId)", body: NameRequest(name: name))
    }

    public func setGroupDescription(groupId: String, description: String) async throws -> GroupState {
        try await request("PUT", "v1/groups/\(groupId)", body: DescriptionRequest(description: description))
    }

    public func setGroupAvatarId(groupId: String, avatarId: String) async throws -> GroupState {
        try await request("PUT", "v1/groups/\(groupId)", body: AvatarIdRequest(avatarId: avatarId))
    }

    public func createGroupInvite(groupId: String) async throws -> GroupInviteResponse {
        try await request("POST", "v1/groups/\(groupId)/invite", body: nil as String?)
    }

    public func joinGroupByInvite(token: String) async throws -> GroupState {
        try await request("POST", "v1/groups/join", body: TokenRequest(token: token))
    }

    public func promoteGroupAdmin(groupId: String, account: String) async throws -> GroupState {
        try await request("POST", "v1/groups/\(groupId)/admins/\(account)", body: nil as String?)
    }

    public func demoteGroupAdmin(groupId: String, account: String) async throws -> GroupState {
        try await request("DELETE", "v1/groups/\(groupId)/admins/\(account)", body: nil as String?)
    }

    public func setGroupAnnounceOnly(groupId: String, announceOnly: Bool) async throws -> GroupState {
        struct Req: Encodable { let announceOnly: Bool }
        return try await request("PUT", "v1/groups/\(groupId)/announce", body: Req(announceOnly: announceOnly))
    }

    // MARK: - Attachments (opaque encrypted blobs)

    /// Allocates a blob id, then uploads the encrypted bytes to it. Returns
    /// the id to put in the AttachmentPointer.
    public func uploadAttachment(_ ciphertext: Data) async throws -> String {
        struct Response: Decodable { let id: String }
        let created: Response = try await request(
            "POST", "v1/attachments", body: nil as [String: String]?
        )
        var request = makeRequest("PUT", "v1/attachments/\(created.id)", authenticated: true)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = ciphertext
        _ = try await send(request)
        return created.id
    }

    /// Downloads an encrypted blob by id (raw ciphertext).
    public func downloadAttachment(id: String) async throws -> Data {
        let request = makeRequest("GET", "v1/attachments/\(id)", authenticated: true)
        let (data, _) = try await send(request)
        return data
    }

    // MARK: - Request plumbing

    private func makeRequest(_ method: String, _ path: String, authenticated: Bool) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.assumesHTTP3Capable = true
        if authenticated, let credentials {
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            throw RelayAPIError.http(status: http.statusCode, message: message)
        }
        return (data, http.statusCode)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: String, body: Body?, authenticated: Bool = true
    ) async throws -> Response {
        var request = makeRequest(method, path, authenticated: authenticated)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func requestExpectingNoContent<Body: Encodable>(
        _ method: String, _ path: String, body: Body
    ) async throws {
        var request = makeRequest(method, path, authenticated: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await send(request)
    }
}

// MARK: - Groups

/// A group's roster + state as returned by the relay.
public struct GroupState: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let avatarId: String
    public let distributionId: String
    public let revision: Int64
    public let members: [String]
    public let admins: [String]
    public let announceOnly: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        avatarId = (try? c.decode(String.self, forKey: .avatarId)) ?? ""
        distributionId = try c.decode(String.self, forKey: .distributionId)
        revision = try c.decode(Int64.self, forKey: .revision)
        members = try c.decode([String].self, forKey: .members)
        admins = (try? c.decode([String].self, forKey: .admins)) ?? []
        announceOnly = (try? c.decode(Bool.self, forKey: .announceOnly)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, avatarId, distributionId, revision, members, admins, announceOnly
    }
}

public struct GroupInviteResponse: Decodable, Sendable {
    public let token: String
    public let url: String
}

/// Time-limited TURN credentials in coturn REST API format.
public struct TurnCredentials: Decodable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String
    /// Lifetime in seconds from issue time.
    public let ttl: Int
}

public struct LinkedDevice: Decodable, Sendable, Identifiable {
    public let deviceId: UInt32
    public let mailboxId: String?
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
    let auth: DeviceMutationAuthorization
}

private struct DeviceMutationRequest: Encodable {
    let auth: DeviceMutationAuthorization
}

private struct DeviceLinkClaimRequest: Encodable {
    let linkToken: String
    let verificationCode: String
}

private struct CreateGroupRequest: Encodable {
    let name: String
    let members: [String]
}

private struct AccountRequest: Encodable {
    let account: String
}

private struct NameRequest: Encodable {
    let name: String
}

private struct DescriptionRequest: Encodable {
    let description: String
}

private struct AvatarIdRequest: Encodable {
    let avatarId: String
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

    init(_ publication: PreKeyPublication) {
        registrationId = publication.registrationId
        identityKey = publication.identityKey.base64EncodedString()
        signedPreKey = SignedPreKeyDTO(publication.signedPreKey)
        kyberPreKey = SignedPreKeyDTO(publication.kyberPreKey)
        oneTimePreKeys = publication.oneTimePreKeys.map(OneTimePreKeyDTO.init)
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
