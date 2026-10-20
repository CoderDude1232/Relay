//
//  ContactSyncView.swift
//  Relay
//
//  Matches address book emails against Relay accounts with blinded discovery.
//  Runs only when the user taps "Find contacts on Relay", after a one-time
//  consent prompt.
//

import Contacts
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

struct ContactSyncView: View {
    let service: MessagingService

    private struct AddressEntry: Sendable { let name: String; let email: String; let avatar: Data? }

    private nonisolated static func readAddressBook() -> [AddressEntry] {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var entries: [AddressEntry] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            for address in contact.emailAddresses {
                let email = (address.value as String).lowercased()
                entries.append(AddressEntry(name: name.isEmpty ? email : name,
                                            email: email,
                                            avatar: contact.thumbnailImageData))
            }
        }
        return entries
    }

    @Environment(AppModel.self) private var model
    @State private var status: SyncStatus = .idle
    @State private var matches: [ContactMatch] = []
    @State private var denied = false
    @State private var startingAccountId: String?
    @State private var messageError: String?
    @State private var showingConsent = false

    enum SyncStatus: Equatable { case idle, loading, done, failed(String) }

    struct ContactMatch: Identifiable {
        let id: String          // accountId
        let contactName: String
        let username: String
        let avatarData: Data?
        var hasConversation: Bool
    }

    var body: some View {
        List {
            Section {
                Button {
                    requestSync()
                } label: {
                    Label("Find contacts on Relay", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(status == .loading)
            } footer: {
                Text(ContactDiscoveryConsent.explanation)
            }

            if status == .loading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }

            if denied {
                Section {
                    Label("Contacts access denied. Allow it in Settings → Relay.", systemImage: "person.slash")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Button("Open Settings") { openAppSettings() }
                }
            }

            if case .failed(let message) = status {
                Section {
                    ContentUnavailableView {
                        Label("Couldn't Check Contacts", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await sync() } }
                            .buttonStyle(.bordered)
                    }
                }
                .listRowBackground(Color.clear)
            }

            if status == .done && matches.isEmpty && !denied {
                Section {
                    ContentUnavailableView(
                        "No Matches Found",
                        systemImage: "person.2",
                        description: Text("None of your contacts are on Relay yet.")
                    )
                }
                .listRowBackground(Color.clear)
            }

            if !matches.isEmpty {
                Section("On Relay") {
                    ForEach(matches) { match in
                        HStack(spacing: 14) {
                            AvatarView(name: match.contactName, size: 44, imageData: match.avatarData)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.contactName).font(.body.weight(.medium))
                                Text("@\(match.username)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if match.hasConversation {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                if startingAccountId == match.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Message") { startConversation(match) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(startingAccountId != nil)
                                }
                            }
                        }
                    }
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Contact Syncing")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Find Contacts on Relay?", isPresented: $showingConsent) {
            Button("Find Contacts") {
                ContactDiscoveryConsent.grant()
                Task { await sync() }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(ContactDiscoveryConsent.explanation)
        }
        .alert("Couldn't Start Chat", isPresented: Binding(
            get: { messageError != nil },
            set: { if !$0 { messageError = nil } }
        )) {
            Button("OK", role: .cancel) { messageError = nil }
        } message: {
            Text(messageError ?? "")
        }
    }

    private func startConversation(_ match: ContactMatch) {
        guard startingAccountId == nil else { return }
        startingAccountId = match.id
        Task {
            defer { startingAccountId = nil }
            do {
                let conversationId = try await service.startConversation(username: match.username)
                if let i = matches.firstIndex(where: { $0.id == match.id }) {
                    matches[i].hasConversation = true
                }
                // Same path as a notification tap: switches to Chats and opens it.
                model.pendingNotificationConversationId = conversationId
            } catch {
                messageError = FriendlyError.message(for: error)
            }
        }
    }

    /// Asks for consent the first time; the answer is remembered.
    private func requestSync() {
        if ContactDiscoveryConsent.isGranted {
            Task { await sync() }
        } else {
            showingConsent = true
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func sync() async {
        status = .loading
        denied = false

        let store = CNContactStore()
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)

        if authStatus == .notDetermined {
            guard (try? await store.requestAccess(for: .contacts)) == true else {
                denied = true; status = .done; return
            }
        } else if authStatus == .denied || authStatus == .restricted {
            denied = true; status = .done; return
        }

        // Enumeration is synchronous and slow, so do it off the main thread.
        let entries = await Task.detached(priority: .userInitiated) { Self.readAddressBook() }.value

        // Deduplicate emails (keep first contact name seen for a given email).
        var seen = Set<String>()
        let deduped = entries.filter { seen.insert($0.email).inserted }

        // One blinded pass: the relay never sees plaintext emails, and contacts
        // who aren't on Relay reveal nothing.
        let existingAccountIds = Set(service.conversations.map { $0.peerAccount })
        var found: [ContactMatch] = []
        let entryByEmail = Dictionary(deduped.map { ($0.email, $0) }, uniquingKeysWith: { a, _ in a })

        let discovered: [(email: String, accountId: String, username: String)]
        do {
            discovered = try await service.discoverContacts(emails: deduped.map { $0.email })
        } catch {
            // A 503 or network failure is not an empty result; offer a retry.
            matches = []
            status = .failed(FriendlyError.message(for: error))
            return
        }
        for match in discovered {
            let entry = entryByEmail[match.email]
            found.append(ContactMatch(
                id: match.accountId,
                contactName: entry?.name ?? match.username,
                username: match.username,
                avatarData: entry?.avatar,
                hasConversation: existingAccountIds.contains(match.accountId)
            ))
        }

        // Existing conversations first, then alphabetical.
        found.sort {
            if $0.hasConversation != $1.hasConversation { return $0.hasConversation }
            return $0.contactName < $1.contactName
        }

        await MainActor.run {
            matches = found
            status = .done
        }
    }
}
