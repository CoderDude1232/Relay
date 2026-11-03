//
//  ProxyAnalysis.swift
//  RelayKit
//
//  A closer look at a proxy before it's used: how fast and steady it is (a
//  proxy could slow people down on purpose), where it connects to the internet
//  from, and whether anything about it looks off. Everything is measured
//  against Relay's own servers: the location comes from Cloudflare's trace page
//  on the relay's domain, which reports the country of the address that
//  reached it, so no third-party lookup service learns which proxy is in use.
//  Findings are warnings only; the person decides.
//

import Darwin
import Foundation

public struct ProxyReport: Equatable, Sendable {
    public enum Warning: Equatable, Sendable, Hashable {
        /// Requests take this long on average.
        case slow(milliseconds: Int)
        /// Downloads crawl, or run far below the direct connection.
        case throttled(kilobytesPerSecond: Int)
        /// Some requests failed or timings jump around.
        case unstable
        /// It reaches the internet from a different address than it's reached at.
        case exitsElsewhere
        /// It's on this local network, so it may be run by that network.
        case localNetwork
        /// Its connection comes out through Tor.
        case tor
    }

    public var status: ProxyStatus
    /// Median time for a small request to the relay through the proxy.
    public var latencyMs: Int?
    public var jitterMs: Int?
    public var failedRequests = 0
    public var downloadKBps: Int?
    /// The same measurements without the proxy, when the relay is reachable directly.
    public var directLatencyMs: Int?
    public var directDownloadKBps: Int?
    /// ISO country code where the proxy reaches the internet ("T1" is Tor).
    public var exitCountry: String?
    public var exitAddress: String?
    /// The addresses the proxy's name points to.
    public var proxyAddresses: [String] = []
    public var warnings: [Warning] = []

    public var isUsable: Bool {
        switch status {
        case .ok, .slow: true
        default: false
        }
    }
}

extension RelayProxy {
    /// Thresholds: below these the proxy is flagged, never refused.
    static let throttledKBps = 100
    public static let unstableJitterMs = 600

    /// Measures `address` against the relay, through it and (if the relay is
    /// reachable) without it, and lists anything worth a second look.
    public static func analyze(_ address: Address, relay: URL) async -> ProxyReport {
        var report = ProxyReport(status: await check(address, relay: relay))
        guard report.isUsable else { return report }

        let proxied = proxiedSession(address)
        defer { proxied.invalidateAndCancel() }
        let direct = URLSession(configuration: {
            let config = RelayTLS.ephemeralConfiguration()
            config.proxyConfigurations = []
            config.timeoutIntervalForRequest = 6
            return config
        }())
        defer { direct.invalidateAndCancel() }

        async let resolved = resolve(address.host)
        async let proxiedTimings = pingTimings(relay: relay, session: proxied, count: 6)
        async let directTimings = pingTimings(relay: relay, session: direct, count: 3)
        let (proxyAddresses, pings, directPings) = await (resolved, proxiedTimings, directTimings)
        report.proxyAddresses = proxyAddresses

        let ok = pings.compactMap { $0 }
        report.failedRequests = pings.count - ok.count
        if !ok.isEmpty {
            let sorted = ok.sorted()
            report.latencyMs = sorted[sorted.count / 2]
            report.jitterMs = (sorted.last ?? 0) - (sorted.first ?? 0)
        }
        let directOk = directPings.compactMap { $0 }.sorted()
        if !directOk.isEmpty { report.directLatencyMs = directOk[directOk.count / 2] }

        report.downloadKBps = await downloadSpeed(relay: relay, session: proxied)
        if report.directLatencyMs != nil {
            report.directDownloadKBps = await downloadSpeed(relay: relay, session: direct)
        }
        if let trace = await cloudflareTrace(relay: relay, session: proxied) {
            report.exitCountry = trace["loc"]
            report.exitAddress = trace["ip"]
        }

        report.warnings = warnings(for: report)
        return report
    }

    static func warnings(for report: ProxyReport) -> [ProxyReport.Warning] {
        var out: [ProxyReport.Warning] = []
        if let latency = report.latencyMs, latency >= slowThresholdMs {
            out.append(.slow(milliseconds: latency))
        }
        if let speed = report.downloadKBps {
            let farBelowDirect = report.directDownloadKBps.map { speed * 4 < $0 && speed < 1000 } ?? false
            if speed < throttledKBps || farBelowDirect { out.append(.throttled(kilobytesPerSecond: speed)) }
        }
        if report.failedRequests > 0 || (report.jitterMs ?? 0) > unstableJitterMs {
            out.append(.unstable)
        }
        if report.exitCountry == "T1" { out.append(.tor) }
        if report.proxyAddresses.contains(where: isLocalAddress) {
            out.append(.localNetwork)
        } else if let exit = report.exitAddress, !report.proxyAddresses.isEmpty,
                  !report.proxyAddresses.contains(exit) {
            out.append(.exitsElsewhere)
        }
        return out
    }

    // MARK: Measurements

    private static func proxiedSession(_ address: Address) -> URLSession {
        let config = RelayTLS.ephemeralConfiguration()
        config.proxyConfigurations = []
        apply(address, to: config)
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    /// Times `count` small requests to the relay; nil for one that failed.
    private static func pingTimings(relay: URL, session: URLSession, count: Int) async -> [Int?] {
        var timings: [Int?] = []
        for _ in 0..<count {
            var request = URLRequest(url: relay.appending(path: "v1/ping"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let start = Date()
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 204 {
                timings.append(Int(Date().timeIntervalSince(start) * 1000))
            } else {
                timings.append(nil)
                // Unreachable directly (the usual reason for a proxy): stop early.
                if timings.count == 1 && count <= 3 { return timings }
            }
        }
        // The first request pays for the TLS handshakes.
        return timings.count > 1 ? Array(timings.dropFirst()) : timings
    }

    /// KB/s for a 256 KB download from the relay.
    private static func downloadSpeed(relay: URL, session: URLSession) async -> Int? {
        var components = URLComponents(url: relay.appending(path: "v1/speedtest"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "kb", value: "256")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 64 * 1024
        else { return nil }
        let seconds = max(Date().timeIntervalSince(start), 0.001)
        return Int(Double(data.count) / 1024 / seconds)
    }

    /// Cloudflare's trace page on the relay's domain: "ip=…" and "loc=…" are
    /// the address that reached Cloudflare (the proxy's exit) and its country.
    private static func cloudflareTrace(relay: URL, session: URLSession) async -> [String: String]? {
        var request = URLRequest(url: relay.appending(path: "cdn-cgi/trace"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data.prefix(4096), encoding: .utf8)
        else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    /// The proxy name's IPv4 and IPv6 addresses.
    private static func resolve(_ host: String) async -> [String] {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: buffer)
                    if !addresses.contains(address) { addresses.append(address) }
                }
                cursor = info.pointee.ai_next
            }
            return addresses
        }.value
    }

    /// Private, link-local and loopback ranges.
    static func isLocalAddress(_ address: String) -> Bool {
        let v4 = address.split(separator: ".").compactMap { Int($0) }
        if v4.count == 4 {
            return v4[0] == 10 || v4[0] == 127 || (v4[0] == 172 && (16...31).contains(v4[1]))
                || (v4[0] == 192 && v4[1] == 168) || (v4[0] == 169 && v4[1] == 254)
                || (v4[0] == 100 && (64...127).contains(v4[1]))
        }
        let lower = address.lowercased()
        return lower == "::1" || lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }
}
