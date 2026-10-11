//
//  RelayProxy.swift
//  RelayKit
//
//  Optional proxy for places that block Relay. Traffic to the relay goes to a
//  volunteer-run relayproxy (server/cmd/relayproxy) as an HTTP CONNECT inside
//  TLS, so the network sees an ordinary HTTPS connection to the proxy's domain
//  and the relay connection inside it stays end-to-end TLS. Stored in the App
//  Group so the extensions use it too. There's no fallback to a direct
//  connection while it's on.
//

import Foundation
import Network

public enum RelayProxy {
    public static let appGroupId = "group.app.relaymsg"
    static let addressKey = "relay.proxy.address"
    static let enabledKey = "relay.proxy.enabled"

    public struct Address: Equatable, Sendable {
        public let host: String
        public let port: UInt16

        public var display: String { port == 443 ? host : "\(host):\(port)" }
        public var shareLink: URL? { URL(string: "https://relaymsg.app/proxy#\(display)") }
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupId) }

    /// The saved address, whether or not the proxy is on.
    public static var savedAddress: Address? {
        defaults?.string(forKey: addressKey).flatMap(parse)
    }

    public static var isEnabled: Bool { defaults?.bool(forKey: enabledKey) ?? false }

    /// The proxy to use right now, if any.
    public static var active: Address? { isEnabled ? savedAddress : nil }

    public static func save(_ address: Address?, enabled: Bool) {
        defaults?.set(address?.display, forKey: addressKey)
        defaults?.set(enabled && address != nil, forKey: enabledKey)
    }

    /// Accepts "host", "host:port", "https://relaymsg.app/proxy#host:port" and
    /// "relay://proxy/host:port".
    public static func parse(_ input: String) -> Address? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text) {
            if url.host == "relaymsg.app", url.path.hasPrefix("/proxy"), let fragment = url.fragment {
                text = fragment
            } else if url.scheme == "relay", url.host == "proxy" {
                text = url.pathComponents.dropFirst().joined(separator: "/")
            }
        }
        if text.hasPrefix("https://") { text = String(text.dropFirst(8)) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = parts.first?.lowercased(), !host.isEmpty, host.count <= 253,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              host.contains(".")
        else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1]) : 443
        guard let port, port > 0 else { return nil }
        return Address(host: host, port: port)
    }

    /// Routes a session through the active proxy.
    static func apply(to config: URLSessionConfiguration) {
        guard let address = active else { return }
        apply(address, to: config)
    }

    static func apply(_ address: Address, to config: URLSessionConfiguration) {
        guard let port = NWEndpoint.Port(rawValue: address.port) else { return }
        var proxy = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(address.host), port: port),
            tlsOptions: NWProtocolTLS.Options()
        )
        proxy.allowFailover = false
        config.proxyConfigurations = [proxy]
    }
}

// MARK: - Health check

/// How a proxy is behaving, from a few requests to the relay through it.
public enum ProxyStatus: Equatable, Sendable {
    case ok(milliseconds: Int)
    /// Working, but slow enough to notice.
    case slow(milliseconds: Int)
    /// The proxy itself can't be reached.
    case unreachable
    /// The proxy answered but wouldn't connect to Relay (blocked or misconfigured).
    case refused
    /// A certificate check failed on the way to Relay: the connection may have
    /// been tampered with, so nothing was sent.
    case securityFailure

    public var isProblem: Bool {
        if case .ok = self { return false }
        return true
    }
}

extension RelayProxy {
    static let slowThresholdMs = 1500

    /// Checks `address` with up to three small requests to the relay through it.
    /// The relay's certificate is verified as usual, so a reply proves the path
    /// reaches the real relay untouched.
    public static func check(_ address: Address, relay: URL) async -> ProxyStatus {
        let config = RelayTLS.ephemeralConfiguration()
        config.proxyConfigurations = []
        apply(address, to: config)
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var timings: [Int] = []
        for _ in 0..<3 {
            var request = URLRequest(url: relay.appending(path: "v1/passkeys"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let start = Date()
            do {
                let (_, response) = try await session.data(for: request)
                // Any HTTP reply comes from the relay itself (401 is expected here).
                guard response is HTTPURLResponse else { return .refused }
                timings.append(Int(Date().timeIntervalSince(start) * 1000))
            } catch let error as URLError {
                return status(for: error)
            } catch {
                return .refused
            }
        }
        // The first request includes both TLS handshakes; judge by the fastest.
        let best = timings.min() ?? 0
        return best >= slowThresholdMs ? .slow(milliseconds: best) : .ok(milliseconds: best)
    }

    static func status(for error: URLError) -> ProxyStatus {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
            return .securityFailure
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .networkConnectionLost, .timedOut:
            return .unreachable
        default:
            return .refused
        }
    }
}
