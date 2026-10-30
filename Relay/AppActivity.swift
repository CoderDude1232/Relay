//
//  AppActivity.swift
//  Relay
//
//  When Relay last came to the foreground, to tell messages that arrive
//  while it's open from ones caught up from the queue on opening.
//

import Foundation
import UIKit

enum AppActivity {
    private static var activeSince: Date?
    private static var observers: [NSObjectProtocol] = []

    /// Call once at launch.
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { activeSince = Date() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { activeSince = nil }
        })
        if UIApplication.shared.applicationState == .active { activeSince = Date() }
    }

    /// A message the relay received moments ago, with Relay open for longer
    /// than that. Anything else was waiting in the queue and its push has
    /// already been shown.
    static func isLive(serverTimestamp: Int64, now: Date = Date()) -> Bool {
        guard let activeSince, now.timeIntervalSince(activeSince) > 2 else { return false }
        let received = Date(timeIntervalSince1970: TimeInterval(serverTimestamp) / 1000)
        return received > activeSince && now.timeIntervalSince(received) < 30
    }
}
