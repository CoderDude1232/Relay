//
//  DebugLogView.swift
//  Relay
//
//  Settings → About → Debug Log: look at the on-device debug log and share it
//  for a bug report. Nothing leaves the device unless the user shares it.
//

import SecureStorage
import SwiftUI
import UniformTypeIdentifiers

struct DebugLogView: View {
    let appVersion: String

    @State private var entries: [DebugLogEntry] = []
    @State private var confirmClear = false

    private var lineCount: Int { entries.count }

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "ladybug.fill", color: .gray, title: "Debug Log",
                             message: "A record of what went wrong on this iPhone, to send to Relay's developers with a bug report.")
                    .settingsBareRow()
            }
            Section {
                ShareLink(item: DebugLogFile(header: Self.header(appVersion: appVersion), entries: entries),
                          preview: SharePreview("Relay debug log")) {
                    SettingsNavRow(systemName: "square.and.arrow.up", color: .blue, title: "Share Debug Log")
                }
                .tint(.primary)
                .disabled(lineCount == 0)
                NavigationLink {
                    DebugLogPreview(entries: entries)
                } label: {
                    SettingsNavRow(systemName: "doc.text.magnifyingglass", color: .gray, title: "View Log")
                }
                .disabled(lineCount == 0)
            } footer: {
                Text(lineCount == 0
                     ? "Nothing logged yet."
                     : "\(lineCount) \(lineCount == 1 ? "line" : "lines") from the last 7 days.")
            }
            Section {
                Button("Clear Debug Log", role: .destructive) { confirmClear = true }
                    .disabled(lineCount == 0)
            } footer: {
                Text("The log never includes messages, names, usernames, account IDs, file names or addresses. Contacts and keys show up only as short codes that mean nothing outside this log. It's kept in Relay's encrypted database for 7 days, is locked away with your messages when Relay forgets them on lock, and is erased when you sign out.")
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog("Clear the debug log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Debug Log", role: .destructive) {
                DebugLog.shared.clear()
                entries = []
            }
        }
    }

    /// Off the main thread: it waits on the database.
    private func reload() async {
        entries = await Task.detached { DebugLog.shared.entries() }.value
    }

    private static func header(appVersion: String) -> [String] {
        let device = UIDevice.current
        return [
            "Relay debug log",
            "Relay \(appVersion) · \(device.systemName) \(device.systemVersion) · \(DeviceModel.hardwareIdentifier)",
            "Exported \(Date().formatted(.iso8601))",
        ]
    }
}

/// The log as a .txt file, built and written only when the user shares it.
nonisolated struct DebugLogFile: Transferable, Sendable {
    let header: [String]
    let entries: [DebugLogEntry]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { file in
            Data(DebugLog.exportText(header: file.header, entries: file.entries).utf8)
        }
        .suggestedFileName("Relay debug log.txt")
    }
}

private struct DebugLogPreview: View {
    let entries: [DebugLogEntry]

    var body: some View {
        List(entries.indices, id: \.self) { index in
            Text(DebugLog.line(entries[index]))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
        .listStyle(.plain)
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
