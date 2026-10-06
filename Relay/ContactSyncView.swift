//
//  ContactSyncView.swift
//  Relay
//
//  Matches address book emails against Relay accounts with blinded discovery.
//  Runs ONLY when the user taps "Find contacts on Relay" (with a one-time
//  explanation + consent that is remembered) — never automatically.
//

import Contacts
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

struct ContactSyncView: View {
    let service: MessagingService

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
        .navigationTitle("Contact Syncing")
        .navigationBarTitleDisplayMode(.inline)
        // Never runs on its own — only from the "Find contacts" button.
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
                messageError = error.localizedDescription
            }
        }
    }

    /// Explicit user action only; the first time asks for informed consent,
    /// which is remembered for later taps.
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

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactEmailAddressesKey, CNContactImageDataKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        // Collect all (name, email, avatar) tuples from address book.
        struct AddressEntry { let name: String; let email: String; let avatar: Data? }
        var entries: [AddressEntry] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            for address in contact.emailAddresses {
                let email = (address.value as String).lowercased()
                entries.append(AddressEntry(name: name.isEmpty ? email : name,
                                            email: email,
                                            avatar: contact.imageData))
            }
        }

        // Deduplicate emails (keep first contact name seen for a given email).
        var seen = Set<String>()
        let deduped = entries.filter { seen.insert($0.email).inserted }

        // Privately match the whole address book against the directory in one
        // blinded pass: the relay never sees the plaintext emails, and contacts
        // who aren't on Relay reveal nothing.
        let existingAccountIds = Set(service.conversations.map { $0.peerAccount })
        var found: [ContactMatch] = []
        let entryByEmail = Dictionary(deduped.map { ($0.email, $0) }, uniquingKeysWith: { a, _ in a })

        let discovered: [(email: String, accountId: String, username: String)]
        do {
            discovered = try await service.discoverContacts(emails: deduped.map { $0.email })
        } catch {
            // A 503 / network failure is not "none of your contacts are on
            // Relay" — say so and offer a retry instead of an empty result.
            matches = []
            status = .failed(error.localizedDescription)
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

        // Sort: existing conversations first, then alphabetically.
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
