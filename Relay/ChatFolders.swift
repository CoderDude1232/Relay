//
//  ChatFolders.swift
//  Relay
//
//  User-defined chat folders. A folder is just a name; each conversation's
//  `label` in the local database says which folder it's in. The folder list
//  lives in this device's preferences and never leaves the phone.
//

import Observation
import SecureStorage
import SwiftUI

@Observable
@MainActor
final class ChatFolderStore {
    static let shared = ChatFolderStore()

    private static let key = "relay.chatFolders"
    static let defaults = ["Personal", "Work", "Family"]
    /// Built-in filters that can't be used as folder names.
    static let reserved: Set<String> = ["all", "unread", "groups"]
    static let maxNameLength = 24

    private(set) var folders: [String]

    private init() {
        folders = UserDefaults.standard.stringArray(forKey: Self.key) ?? Self.defaults
    }

    private func save() {
        UserDefaults.standard.set(folders, forKey: Self.key)
    }

    /// Re-reads the list (after sign-out wipes preferences).
    func reload() {
        folders = UserDefaults.standard.stringArray(forKey: Self.key) ?? Self.defaults
    }

    /// Returns a cleaned name, or nil if it's empty, reserved or already used.
    func validName(_ raw: String, excluding current: String? = nil) -> String? {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        guard !name.isEmpty, !Self.reserved.contains(name.lowercased()) else { return nil }
        let taken = folders.contains { $0.caseInsensitiveCompare(name) == .orderedSame && $0 != current }
        return taken ? nil : name
    }

    @discardableResult
    func add(_ raw: String) -> String? {
        guard let name = validName(raw) else { return nil }
        folders.append(name)
        save()
        return name
    }

    /// Renames a folder and moves its chats along with it.
    func rename(_ old: String, to raw: String, service: MessagingService) {
        guard let name = validName(raw, excluding: old), let i = folders.firstIndex(of: old) else { return }
        folders[i] = name
        save()
        for c in service.conversations where c.label == old {
            service.setConversationLabel(c.id, label: name)
        }
    }

    /// Deletes a folder; its chats go back to "All" only.
    func delete(_ name: String, service: MessagingService) {
        folders.removeAll { $0 == name }
        save()
        for c in service.conversations where c.label == name {
            service.setConversationLabel(c.id, label: nil)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }
}

/// Create, rename, reorder and delete chat folders.
struct ChatFoldersView: View {
    let service: MessagingService
    @State private var store = ChatFolderStore.shared
    @State private var newName = ""
    @State private var showingNew = false
    @State private var renaming: String?
    @State private var renameText = ""

    private func count(_ folder: String) -> Int {
        service.conversations.filter { $0.label == folder && !$0.archived }.count
    }

    var body: some View {
        List {
            Section {
                ForEach(store.folders, id: \.self) { folder in
                    Button {
                        renameText = folder
                        renaming = folder
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "folder.fill", color: .accentColor)
                            Text(folder).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text("\(count(folder))").foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .accessibilityHint("Rename")
                }
                .onMove { store.move(from: $0, to: $1) }
                .onDelete { offsets in
                    for i in offsets.sorted(by: >) { store.delete(store.folders[i], service: service) }
                }
                Button {
                    newName = ""
                    showingNew = true
                } label: {
                    Label("New Folder", systemImage: "plus")
                }
            } footer: {
                Text("Long-press a chat in the list and choose Move to Folder. Folders are kept on this device only. Deleting a folder doesn't delete its chats.")
            }
        }
        .navigationTitle("Chat Folders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .alert("New Folder", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Create") { store.add(newName) }
                .disabled(store.validName(newName) == nil)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let old = renaming { store.rename(old, to: renameText, service: service) }
            }
            .disabled(store.validName(renameText, excluding: renaming) == nil)
            Button("Cancel", role: .cancel) {}
        }
    }
}
