//
//  WireMapping.swift
//  RelayKit
//
//  Bridges CryptoCore's transport-agnostic types to the relay's protobuf
//  wire enums. Kept in one place so a schema change breaks exactly here.
//

import CryptoCore
import Foundation

extension MessageKind {
    var wireType: Relay_V1_CiphertextType {
        switch self {
        case .preKey: .prekeyMessage
        case .message: .message
        case .senderKey: .senderKeyMessage
        }
    }

    init?(wireType: Relay_V1_CiphertextType) {
        switch wireType {
        case .prekeyMessage: self = .preKey
        case .message: self = .message
        case .senderKeyMessage: self = .senderKey
        default: return nil
        }
    }
}

/// One decrypted-ready ciphertext received from the relay.
public struct IncomingEnvelope: Sendable, Equatable {
    public let id: String
    public let senderAccount: String
    public let senderDevice: UInt32
    public let message: SecureMessage
    public let clientTimestamp: Int64
    public let serverTimestamp: Int64
    public let ephemeral: Bool

    /// Builds an envelope from the serialized `relay.v1.Envelope` bytes — used
    /// by the Notification Service Extension, which receives the envelope in
    /// the APNs payload rather than over the WebSocket.
    public init?(serializedEnvelope data: Data) {
        guard let proto = try? Relay_V1_Envelope(serializedBytes: data) else { return nil }
        self.init(proto)
    }

    init?(_ proto: Relay_V1_Envelope) {
        guard let kind = MessageKind(wireType: proto.type) else { return nil }
        self.id = proto.id
        self.senderAccount = proto.senderAccount
        self.senderDevice = proto.senderDevice
        self.message = SecureMessage(kind: kind, data: proto.content)
        self.clientTimestamp = proto.clientTimestamp
        self.serverTimestamp = proto.serverTimestamp
        self.ephemeral = proto.ephemeral
    }
}

/// A ciphertext addressed to one specific device of the destination
/// account (the per-device fan-out unit).
public struct DeviceMessagePayload: Sendable, Equatable {
    public let deviceId: UInt32
    /// Recipient's registration id as known to our session; 0 skips the
    /// server-side staleness check.
    public let registrationId: UInt32
    public let message: SecureMessage

    public init(deviceId: UInt32, registrationId: UInt32, message: SecureMessage) {
        self.deviceId = deviceId
        self.registrationId = registrationId
        self.message = message
    }

    var proto: Relay_V1_DeviceMessage {
        var out = Relay_V1_DeviceMessage()
        out.deviceID = deviceId
        out.registrationID = registrationId
        out.type = message.kind.wireType
        out.content = message.data
        return out
    }
}

/// The relay's verdict on a send.
public enum SendOutcome: Sendable, Equatable {
    case ok(serverTimestamp: Int64)
    /// The fan-out didn't cover the account's devices; re-fetch bundles,
    /// re-encrypt for the listed devices and retry.
    case mismatchedDevices(missing: [UInt32], extra: [UInt32], stale: [UInt32])
    case unknownAccount
    case rateLimited
    case serverError

    init(_ proto: Relay_V1_SendResponse) {
        switch proto.status {
        case .ok:
            self = .ok(serverTimestamp: proto.serverTimestamp)
        case .mismatchedDevices:
            self = .mismatchedDevices(
                missing: proto.missingDevices,
                extra: proto.extraDevices,
                stale: proto.staleDevices
            )
        case .unknownAccount:
            self = .unknownAccount
        case .rateLimited:
            self = .rateLimited
        default:
            self = .serverError
        }
    }
}
