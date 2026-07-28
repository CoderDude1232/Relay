//
//  RelayWebSocket.swift
//  RelayKit
//
//  Real-time channel to the relay. Each WebSocket binary message is one
//  protobuf ClientFrame (out) or ServerFrame (in). On connect the server
//  drains the offline queue, then signals `.queueDrained`; everything after
//  is live. Delivery is at-least-once — consumers ack envelopes once
//  they're durably stored, and must dedup by envelope id.
//
//  Reconnection policy lives with the caller (the messaging service);
//  this actor represents exactly one connection.
//

import Foundation

public enum RelayEvent: Sendable {
    case envelope(IncomingEnvelope)
    /// Offline queue fully delivered; subsequent envelopes are real-time.
    case queueDrained
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

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var nextRequestId: UInt64 = 1
    private var pendingSends: [UInt64: CheckedContinuation<Relay_V1_SendResponse, any Error>] = [:]

    private var eventContinuation: AsyncStream<RelayEvent>.Continuation?

    public init(baseURL: URL, credentials: RelayCredentials, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
    }

    /// Opens the socket and returns the event stream. The stream yields
    /// queued envelopes, then `.queueDrained`, then live traffic, and
    /// finishes after `.disconnected`.
    public func connect() -> AsyncStream<RelayEvent> {
        disconnectInternal()

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!.appending(path: "v1/ws"))
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        let (stream, continuation) = AsyncStream.makeStream(of: RelayEvent.self)
        eventContinuation = continuation

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(task)
        }
        return stream
    }

    public func disconnect() {
        disconnectInternal()
    }

    /// Fan-out send; suspends until the relay's verdict arrives.
    public func send(
        to destinationAccount: String,
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
        send.destinationAccount = destinationAccount
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

    /// Confirms durable receipt; the relay then drops the envelope from
    /// this device's queue.
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
            case .none:
                break
            }
        }
    }

    private func failPendingSend(_ id: UInt64, error: any Error) {
        pendingSends.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handleDisconnect() {
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
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if eventContinuation != nil {
            handleDisconnect()
        }
    }
}
