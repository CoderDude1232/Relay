//
//  ContactSyncView.swift
//  Relay
//
//  Matches address book emails against Relay accounts via server lookup.
//  Each email is checked against GET /v1/accounts/by-email — no bulk upload,
//  no contact list stored on server. Lookups are authenticated so the server
//  can rate-limit abuse.
//

import Contacts
import RelayKit
import SecureStorage
import SwiftUI

struct ContactSyncView: View {
    let service: MessagingService

    @State private var status: SyncStatus = .idle
    @State private var matches: [ContactMatch] = []
    @State private var denied = false

    enum SyncStatus { case idle, loading, done }

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
                Text("Relay checks your address book emails against accounts on the server. Your contacts are never uploaded — each email is looked up individually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                }
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
                                Button("Message") {
                                    Task { _ = try? await service.startConversation(username: match.username) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Contact Syncing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sync") { Task { await sync() } }
                    .disabled(status == .loading)
            }
        }
        .task { await sync() }
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

        // Look up each email on the server. Fire requests concurrently but
        // cap concurrency to 10 so we don't hammer the rate limiter.
        let existingAccountIds = Set(service.conversations.map { $0.peerAccount })
        var found: [ContactMatch] = []

        await withTaskGroup(of: ContactMatch?.self) { group in
            var inFlight = 0
            var iterator = deduped.makeIterator()

            func enqueue() {
                while inFlight < 10, let entry = iterator.next() {
                    inFlight += 1
                    let e = entry
                    group.addTask {
                        guard let (accountId, username) = try? await service.apiClient.lookupAccount(byEmail: e.email)
                        else { return nil }
                        return ContactMatch(
                            id: accountId,
                            contactName: e.name,
                            username: username,
                            avatarData: e.avatar,
                            hasConversation: existingAccountIds.contains(accountId)
                        )
                    }
                }
            }

            enqueue()
            for await result in group {
                inFlight -= 1
                if let match = result { found.append(match) }
                enqueue()
            }
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
