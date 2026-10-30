//
//  MessageTone.swift
//  RelayCore
//
//  Relay's own new-message notification sound. The app copies it into the
//  App Group's Library/Sounds, where iOS finds it for banners the
//  notification extension builds.
//

import Foundation

public enum MessageTone {
    public static let fileName = "relay-message.caf"

    /// Copies the tone from `bundle` into the shared container, once per
    /// change of the file.
    public static func install(from bundle: Bundle = .main, appGroupId: String = RelayStore.appGroupId) {
        let fm = FileManager.default
        guard let source = bundle.url(forResource: "relay-message", withExtension: "caf"),
              let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
        else { return }
        let dir = container.appendingPathComponent("Library/Sounds", isDirectory: true)
        let target = dir.appendingPathComponent(fileName)
        if let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: target), a == b { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: source, to: target)
    }
}
