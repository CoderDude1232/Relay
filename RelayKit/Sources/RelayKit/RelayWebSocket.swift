//
//  RelayWebSocket.swift
//  RelayKit
//
//  Real-time channel to the relay. Each binary message is one protobuf
//  ClientFrame (out) or ServerFrame (in). On connect the server drains the
//  offline queue and then sends `.queueDrained`; everything after is live.
//  Delivery is at-least-once: ack envelopes once durably stored, dedup by
//  envelope id.
//
//  One actor per connection; reconnection is up to the caller.
//

import Foundation
import OSLog

public enum RelayEvent: Sendable {
    case envelope(IncomingEnvelope)
    /// The offline queue is delivered; later envelopes are live.
    case queueDrained
    /// A signed remote-wipe command. Verify the signature before wiping.
    case nukeCommand(NukeEvent)
    /// The account's device list changed.
    case deviceListChanged(DeviceListChangedEvent)
    /// The connection ended; the stream finishes after this event.
    case disconnected
}

public enum RelayWebSocketError: Error {
    case notConnected
    case connectionClosed
}

public actor RelayWebSocket {
    private let baseURL: URL
    private let credentials: RelayCredentials
    private let session: URLSession
    private let signer: (any RelayRequestSigner)?

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var nextRequestId: UInt64 = 1
    private var pendingSends: [UInt64: CheckedContinuation<Relay_V1_SendResponse, any Error>] = [:]

    private var eventContinuation: AsyncStream<RelayEvent>.Continuation?
    private let log = Logger(subsystem: "com.relaytextingapp.RelayKit", category: "websocket")

    /// - Parameter signer: the device auth key, used to sign the upgrade with
    ///   Relay-Sig v2. The relay refuses HTTP Basic once a device has an auth key,
    ///   so pass the same signer as the REST client. Basic is used only without one.
    public init(baseURL: URL, credentials: RelayCredentials, session: URLSession = RelayTLS.sharedSession,
                signer: (any RelayRequestSigner)? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        self.signer = signer
    }

    /// Opens the socket. The stream yields queued envelopes, `.queueDrained`,
    /// then live traffic, and finishes after `.disconnected`.
    public func connect() -> AsyncStream<RelayEvent> {
        disconnectInternal()

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            let (stream, continuation) = AsyncStream.makeStream(of: RelayEvent.self)
            continuation.finish()
            return stream
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let wsBaseURL = components.url else {
            let (stream, continuation) = AsyncStream.makeStream(of: RelayEvent.self)
            continuation.finish()
            return stream
        }
        let url = wsBaseURL.appending(path: "v1/ws")
        var request = URLRequest(url: url)
        // Don't set assumesHTTP3Capable. On a device it makes iOS try the
        // WebSocket over QUIC, which the server doesn't support; the connection
        // stalls and is reset (POSIX 57). The handshake must go over TCP.
        if let signer {
            // Sign the upgrade as the server sees it: GET /v1/ws, empty body.
            if !RelaySignature.sign(&request, credentials: credentials, signer: signer) {
                log.warning("websocket upgrade signing failed")
            }
        } else {
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        log.info("connecting to websocket endpoint")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        let (stream, continuation) = AsyncStream.makeStream(of: RelayEvent.self)
        eventContinuation = continuation

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(task)
        }
        pingLoop = Task { [weak self] in
            await self?.runPingLoop(task)
        }
        return stream
    }

    public func disconnect() {
        disconnectInternal()
    }

    /// Sends encrypted payloads to a destination mailbox. The proto field is
    /// named `destinationAccount` but the server treats it as an opaque mailbox id.
    public func send(
        to destinationMailbox: String,
        messages: [DeviceMessagePayload],
        clientTimestamp: Int64,
        ephemeral: Bool = false
    ) async throws -> SendOutcome {
        guard let task else { throw RelayWebSocketError.notConnected }

        var frame = Relay_V1_ClientFrame()
        let requestId = nextRequestId
        nextRequestId += 1
        frame.id = requestId
        var send = Relay_V1_SendRequest()
        send.destinationAccount = destinationMailbox
        send.messages = messages.map(\.proto)
        send.clientTimestamp = clientTimestamp
        send.ephemeral = ephemeral
        frame.send = send

        let data = try frame.serializedData()
        let response = try await withCheckedThrowingContinuation { continuation in
            pendingSends[requestId] = continuation
            task.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { await self?.failPendingSend(requestId, error: error) }
            }
        }
        return SendOutcome(response)
    }

    /// Confirms durable receipt so the relay drops the envelope from this
    /// device's queue.
    public func ack(envelopeId: String) async throws {
        guard let task else { throw RelayWebSocketError.notConnected }
        var frame = Relay_V1_ClientFrame()
        var ack = Relay_V1_AckRequest()
        ack.envelopeID = envelopeId
        frame.ack = ack
        try await task.send(.data(frame.serializedData()))
    }

    // MARK: - Internals

    private func runReceiveLoop(_ task: URLSessionWebSocketTask) async {
        defer { handleDisconnect() }
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                log.warning("websocket receive failed")
                return
            }
            guard case .data(let data) = message,
                  let frame = try? Relay_V1_ServerFrame(serializedBytes: data)
            else { continue }

            switch frame.payload {
            case .sendResponse(let response):
                pendingSends.removeValue(forKey: response.replyTo)?.resume(returning: response)
            case .envelope(let proto):
                if let envelope = IncomingEnvelope(proto) {
                    eventContinuation?.yield(.envelope(envelope))
                }
            case .queueEmpty:
                eventContinuation?.yield(.queueDrained)
            case .nuke(let nuke):
                eventContinuation?.yield(.nukeCommand(NukeEvent(nuke)))
            case .deviceListChanged(let change):
                eventContinuation?.yield(.deviceListChanged(DeviceListChangedEvent(change)))
            case .none:
                break
            }
        }
    }

    /// Pings every 25s. The transport or Cloudflare otherwise tears down idle
    /// sockets silently ("nw_read Operation timed out" on a receive-only device),
    /// and the client only notices on a slow reconnect. A failed ping means the
    /// socket is dead, so tear it down to reconnect right away.
    private func runPingLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, self.task === task else { return }
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                task.sendPing { error in cont.resume(returning: error == nil) }
            }
            if !ok {
                log.warning("websocket ping failed; forcing reconnect")
                task.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func failPendingSend(_ id: UInt64, error: any Error) {
        pendingSends.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handleDisconnect() {
        pingLoop?.cancel()
        pingLoop = nil
        for continuation in pendingSends.values {
            continuation.resume(throwing: RelayWebSocketError.connectionClosed)
        }
        pendingSends.removeAll()
        eventContinuation?.yield(.disconnected)
        eventContinuation?.finish()
        eventContinuation = nil
        task = nil
    }

    private func disconnectInternal() {
        receiveLoop?.cancel()
        receiveLoop = nil
        pingLoop?.cancel()
        pingLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if eventContinuation != nil {
            handleDisconnect()
        }
    }
}
