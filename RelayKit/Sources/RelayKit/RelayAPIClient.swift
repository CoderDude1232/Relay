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
    public func register(username: String, password: String) async throws -> RelayCredentials {
        struct Response: Decodable {
            let accountId: String
            let deviceId: UInt32
        }
        let response: Response = try await request(
            "POST", "v1/accounts",
            body: ["username": username, "password": password],
            authenticated: false
        )
        return RelayCredentials(
            accountId: response.accountId,
            deviceId: response.deviceId,
            password: password
        )
    }

    public func lookupAccount(username: String) async throws -> String {
        struct Response: Decodable { let accountId: String }
        let response: Response = try await request(
            "GET", "v1/accounts/by-username/\(username)", body: nil as [String: String]?
        )
        return response.accountId
    }

    public func lookupUsername(account: String) async throws -> String {
        struct Response: Decodable { let username: String }
        let response: Response = try await request(
            "GET", "v1/accounts/\(account)", body: nil as [String: String]?
        )
        return response.username
    }

    public func setAPNSToken(_ token: String) async throws {
        try await requestExpectingNoContent("PUT", "v1/devices/apns", body: ["token": token])
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
        struct Response: Decodable { let devices: [BundleDTO] }
        let response: Response = try await request(
            "GET", "v1/keys/\(account)", body: nil as [String: String]?
        )
        return try response.devices.map { try $0.model() }
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
    public let distributionId: String
    public let revision: Int64
    public let members: [String]
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
            registrationId: registrationId,
            identityKey: identity,
            signedPreKey: try signedPreKey.model(),
            kyberPreKey: try kyberPreKey.model(),
            oneTimePreKey: try oneTimePreKey?.model()
        )
    }
}
