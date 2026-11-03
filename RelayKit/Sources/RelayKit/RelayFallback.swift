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

import CryptoKit
import Foundation

public enum RelayFallback {
    static let hostsKey = "relay.fallback.hosts"
    static let activeKey = "relay.fallback.active"
    static let activeAtKey = "relay.fallback.activeAt"
    static let fetchedAtKey = "relay.fallback.fetchedAt"
    /// How long to stay on a backup before trying the main address again.
    static let retryPrimaryAfter: TimeInterval = 15 * 60

    private static var defaults: UserDefaults? { UserDefaults(suiteName: RelayProxy.appGroupId) }

    /// A Worker that's never rotated, for devices that haven't fetched the list
    /// yet (a new install on a network that already blocks the relay).
    /// cmd/fallbackrotate keeps it deployed (-anchor).
    static let builtIn = ["paperlantern.amberfield.workers.dev"]

    // MARK: Published list

    /// The same list, signed by the rotation (cmd/fallbackrotate), on GitHub:
    /// where a device that can't reach the relay may still find the newest
    /// addresses. Only a list signed with `listSigningKey` is used, so a fake
    /// copy can't point the app anywhere else.
    static let publishedListURL = URL(string: "https://gist.githubusercontent.com/CoderDude1232/02b29ce6632a4784f37e1902e11aea5b/raw/fallbacks.json")!
    static let listSigningKey = "nyQLXvGVbFxNzCHPNen9oah2CHGlTUZV7LReGFqWM5k="
    static let issuedKey = "relay.fallback.issued"
    static let publishedCheckedKey = "relay.fallback.publishedChecked"

    /// Fetches the published list and keeps it if it's genuine and newer than
    /// what's saved. At most every few minutes.
    static func refreshFromPublishedList(session: URLSession) async {
        let now = Date().timeIntervalSince1970
        guard now - (defaults?.double(forKey: publishedCheckedKey) ?? 0) > 5 * 60 else { return }
        defaults?.set(now, forKey: publishedCheckedKey)
        var request = URLRequest(url: publishedListURL, timeoutInterval: 6)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = verifiedList(data),
              list.issued > Int64(defaults?.double(forKey: issuedKey) ?? 0)
        else { return }
        defaults?.set(Double(list.issued), forKey: issuedKey)
        defaults?.set(list.hosts, forKey: hostsKey)
    }

    /// The hosts in a signed list, or nil unless the signature checks out.
    static func verifiedList(_ data: Data) -> (issued: Int64, hosts: [String])? {
        struct Signed: Decodable { let v: Int; let issued: Int64; let hosts: [String]; let sig: String }
        guard let signed = try? JSONDecoder().decode(Signed.self, from: data), signed.v == 1,
              let sig = Data(base64Encoded: signed.sig),
              let keyData = Data(base64Encoded: listSigningKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return nil }
        let message = "relay-fallbacks-v1\n\(signed.issued)\n" + signed.hosts.map { $0 + "\n" }.joined()
        guard key.isValidSignature(sig, for: Data(message.utf8)) else { return nil }
        // Hostnames only: never a path, port or anything else.
        let hosts = signed.hosts.filter { host in
            host.count <= 253 && host.contains(".")
                && host.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }
        }
        return (signed.issued, Array(hosts.prefix(10)))
    }

    /// The backups the relay last sent, newest first, then the built-in one.
    public static var hosts: [String] {
        let fetched = defaults?.stringArray(forKey: hostsKey) ?? []
        return fetched + builtIn.filter { !fetched.contains($0) }
    }

    /// Saves the relay's list. A backup in use that's no longer listed is dropped.
    public static func save(hosts: [String]) {
        defaults?.set(hosts, forKey: hostsKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: fetchedAtKey)
        if let active = activeHost, !Self.hosts.contains(active) { setActive(nil) }
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
    /// network filter blocked the main address, to test the fallback;
    /// `-relaySimulateBlockedAPI all` blocks the backups too.
    static var simulatesBlockedPrimary: Bool { UserDefaults.standard.string(forKey: "relaySimulateBlockedAPI") != nil }
    static var simulatesBlockedEverything: Bool { UserDefaults.standard.string(forKey: "relaySimulateBlockedAPI") == "all" }

    static func simulatesBlocked(_ host: String?) -> Bool {
        simulatesBlockedEverything || (simulatesBlockedPrimary && host == "api.relaymsg.app")
    }
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

    /// Worth looking for another address, though the request may have arrived
    /// (a filter that silently drops the connection looks like a timeout).
    static func suggestsBlock(_ error: Error) -> Bool {
        isUnreachable(error) || (error as? URLError)?.code == .timedOut
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
                // The newest addresses first, if GitHub is reachable.
                await RelayFallback.refreshFromPublishedList(session: session)
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
        if simulatesBlocked(host) { return false }
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
