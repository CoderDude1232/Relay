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
        guard let address = active, let port = NWEndpoint.Port(rawValue: address.port) else { return }
        var proxy = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(address.host), port: port),
            tlsOptions: NWProtocolTLS.Options()
        )
        proxy.allowFailover = false
        config.proxyConfigurations = [proxy]
    }
}
