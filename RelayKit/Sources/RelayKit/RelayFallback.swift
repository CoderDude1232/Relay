//
//  RelayFallback.swift
//  RelayKit
//
//  Backup addresses for networks that block api.relaymsg.app by name (school
//  and work filters). The relay hands signed-in devices a short list of
//  Cloudflare Workers that pass requests through to it unchanged
//  (server/cmd/fallbackrotate); the names rotate every few days. When the main
//  address can't be reached, requests move to the first backup that answers,
//  and the main address is tried again after a while. Off while a proxy is on,
//  since the proxy already gets around the block. Stored in the App Group so the
//  extensions follow along.
//

import Foundation

public enum RelayFallback {
    static let hostsKey = "relay.fallback.hosts"
    static let activeKey = "relay.fallback.active"
    static let activeAtKey = "relay.fallback.activeAt"
    static let fetchedAtKey = "relay.fallback.fetchedAt"
    /// How long to stay on a backup before trying the main address again.
    static let retryPrimaryAfter: TimeInterval = 15 * 60

    private static var defaults: UserDefaults? { UserDefaults(suiteName: RelayProxy.appGroupId) }

    /// The backups the relay last sent, newest first.
    public static var hosts: [String] { defaults?.stringArray(forKey: hostsKey) ?? [] }

    /// Saves the relay's list. A backup in use that's no longer listed is dropped.
    public static func save(hosts: [String]) {
        defaults?.set(hosts, forKey: hostsKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: fetchedAtKey)
        if let active = activeHost, !hosts.contains(active) { setActive(nil) }
    }

    /// True when the list is old enough to fetch again.
    public static var isListStale: Bool {
        let fetched = defaults?.double(forKey: fetchedAtKey) ?? 0
        return Date().timeIntervalSince1970 - fetched > 6 * 3600
    }

    /// The backup in use, if any (stored even when it's time to retry the main address).
    static var activeHost: String? { defaults?.string(forKey: activeKey) }

    static func setActive(_ host: String?) {
        defaults?.set(host, forKey: activeKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: activeAtKey)
    }

    /// The host requests should go to right now in place of `primary`.
    static func currentHost(primary: String) -> String? {
        guard RelayProxy.active == nil, let active = activeHost else { return nil }
        let since = defaults?.double(forKey: activeAtKey) ?? 0
        // Due for another try of the main address: the next failure moves back.
        if Date().timeIntervalSince1970 - since > retryPrimaryAfter { return nil }
        return active == primary ? nil : active
    }

    /// `url` with the relay's host swapped for the backup in use, if any.
    public static func route(_ url: URL) -> URL {
        guard let primary = url.host(), let host = currentHost(primary: primary),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.host = host
        components.port = nil
        return components.url ?? url
    }

    #if DEBUG
    /// Debug builds launched with `-relaySimulateBlockedAPI YES` act as if a
    /// network filter blocked the main address, to test the fallback.
    static var simulatesBlockedPrimary: Bool { UserDefaults.standard.bool(forKey: "relaySimulateBlockedAPI") }
    #endif

    /// A failure that means this address couldn't be reached at all (not a
    /// slow or broken response), so the request never got to the relay and
    /// trying another address is safe.
    static func isUnreachable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }

    /// After `failedHost` couldn't be reached: picks the first address (the main
    /// one included) that answers as the relay and returns it, or nil if none do.
    static func failover(primary: String, failedHost: String, session: URLSession) async -> String? {
        await Coordinator.shared.failover(primary: primary, failedHost: failedHost, session: session)
    }

    /// One failover at a time; requests that fail together share its answer.
    private actor Coordinator {
        static let shared = Coordinator()
        private var running: Task<String?, Never>?

        func failover(primary: String, failedHost: String, session: URLSession) async -> String? {
            if let running { return await running.value }
            let task = Task<String?, Never> {
                let candidates = ([primary] + RelayFallback.hosts).filter { $0 != failedHost }
                for host in candidates where await RelayFallback.answers(host, session: session) {
                    RelayFallback.setActive(host == primary ? nil : host)
                    return host
                }
                return nil
            }
            running = task
            let result = await task.value
            running = nil
            return result
        }
    }

    /// The relay answers `/v1/ping` with 204 and X-Relay: 1; a block page doesn't.
    static func answers(_ host: String, session: URLSession) async -> Bool {
        #if DEBUG
        if simulatesBlockedPrimary, host == "api.relaymsg.app" { return false }
        #endif
        guard let url = URL(string: "https://\(host)/v1/ping") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 204 && http.value(forHTTPHeaderField: "X-Relay") == "1"
    }
}
