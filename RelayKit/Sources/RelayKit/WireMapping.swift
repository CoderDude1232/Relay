//
//  WireMapping.swift
//  RelayKit
//
//  Maps CryptoCore's transport-agnostic types to the relay's protobuf enums.
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

/// One ciphertext received from the relay.
public struct IncomingEnvelope: Sendable, Equatable {
    public let id: String
    public let senderAccount: String
    public let senderDevice: UInt32
    public let message: SecureMessage
    public let clientTimestamp: Int64
    public let serverTimestamp: Int64
    public let ephemeral: Bool

    /// Builds an envelope from serialized `relay.v1.Envelope` bytes, as delivered
    /// to the NSE in the APNs payload.
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

/// A ciphertext for one device of the destination account.
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
    /// The fan-out didn't match the account's devices. Re-fetch bundles,
    /// re-encrypt for the listed devices, and retry.
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

/// A signed remote-wipe command. Verify the signature before wiping.
public struct NukeEvent: Sendable, Equatable {
    public let accountId: String
    public let commandId: String
    public let creationTimeMs: Int64
    public let initiatingDeviceId: UInt32
    /// ECDSA P-256 DER signature over the canonical nuke payload.
    public let signature: Data

    init(_ proto: Relay_V1_NukeCommand) {
        self.accountId = proto.accountID
        self.commandId = proto.commandID
        self.creationTimeMs = proto.creationTimeMs
        self.initiatingDeviceId = proto.initiatingDeviceID
        self.signature = proto.signature
    }
}

/// Notifies the client that the account's device list changed.
public struct DeviceListChangedEvent: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case added, removed, unknown
    }
    public let action: Action
    public let deviceId: UInt32

    init(_ proto: Relay_V1_DeviceListChanged) {
        switch proto.action {
        case .deviceAdded: self.action = .added
        case .deviceRemoved: self.action = .removed
        default: self.action = .unknown
        }
        self.deviceId = proto.deviceID
    }
}
