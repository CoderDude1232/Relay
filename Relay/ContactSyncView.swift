//
//  ContactSyncView.swift
//  Relay
//
//  Matches address book emails against known Relay conversation usernames.
//  Only does a local cross-reference — no contact data leaves the device.
//

import Contacts
import SecureStorage
import SwiftUI

struct ContactSyncView: View {
    let service: MessagingService

    @State private var status: SyncStatus = .idle
    @State private var matches: [ContactMatch] = []
    @State private var denied = false

    enum SyncStatus { case idle, loading, done }

    struct ContactMatch: Identifiable {
        let id: String  // conversation id
        let contactName: String
        let username: String
        let avatarData: Data?
    }

    var body: some View {
        List {
            Section {
                Text("Relay matches your address book emails against conversations you already have open. No data is sent to any server.")
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
                        description: Text("None of your address book emails match open conversations.")
                    )
                }
                .listRowBackground(Color.clear)
            }

            if !matches.isEmpty {
                Section("Matched Contacts") {
                    ForEach(matches) { match in
                        HStack(spacing: 14) {
                            AvatarView(name: match.contactName, size: 44, imageData: match.avatarData)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.contactName).font(.body.weight(.medium))
                                Text("@\(match.username)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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

        var found = [ContactMatch]()
        let conversations = service.conversations

        try? store.enumerateContacts(with: request) { contact, _ in
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            for email in contact.emailAddresses {
                let emailStr = (email.value as String).lowercased()
                if let conv = conversations.first(where: {
                    $0.peerUsername?.lowercased() == emailStr
                }) {
                    found.append(ContactMatch(
                        id: conv.id,
                        contactName: name.isEmpty ? emailStr : name,
                        username: conv.peerUsername ?? emailStr,
                        avatarData: contact.imageData
                    ))
                    break
                }
            }
        }

        await MainActor.run {
            matches = found
            status = .done
        }
    }
}
