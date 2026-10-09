//
//  CallLinksView.swift
//  Relay
//
//  Call links: a shareable link that starts (or joins) a call with whoever
//  opens it, after the host lets them in. See CallManager "Call links" for the
//  protocol; the links themselves are stored on this device only.
//

import Observation
import RelayCore
import RelayKit
import SwiftUI

@Observable
@MainActor
final class CallLinkStore {
    static let shared = CallLinkStore()

    private var defaults: UserDefaults? { UserDefaults(suiteName: AppModel.appGroupId) }
    private(set) var links: [CallLinkRecord] = []

    private init() { reload() }

    func reload() { links = CallLinkRecords.load(defaults: defaults) }

    @discardableResult
    func create(name: String) -> CallLinkRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = CallLinkRecord(
            id: UUID().uuidString, secret: CallLinkRecords.makeSecret(),
            name: trimmed.isEmpty ? "Call link" : String(trimmed.prefix(40)), createdAt: Date()
        )
        links.insert(link, at: 0)
        CallLinkRecords.save(links, defaults: defaults)
        return link
    }

    /// Deleting a link revokes it: requests for it are ignored from then on.
    func delete(_ id: String) {
        links.removeAll { $0.id == id }
        CallLinkRecords.save(links, defaults: defaults)
    }

    func clearAll() {
        links = []
        CallLinkRecords.clear(defaults: defaults)
    }

    func link(_ id: String) -> CallLinkRecord? { links.first { $0.id == id } }
}

/// Calls → Call Links.
struct CallLinksView: View {
    let service: MessagingService
    @Environment(CallManager.self) private var callManager
    @Environment(\.dismiss) private var dismiss
    @State private var store = CallLinkStore.shared
    @State private var showingNew = false
    @State private var newName = ""
    @State private var copiedId: String?

    private var host: String { service.credentials.accountId }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        showingNew = true
                    } label: {
                        Label("Create Call Link", systemImage: "link.badge.plus")
                    }
                } footer: {
                    Text("Anyone with the link can ask to join. You decide who gets in, and the link only works while you're available to let them in. Delete a link to turn it off.")
                }

                if !store.links.isEmpty {
                    Section("Your Links") {
                        ForEach(store.links) { link in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "link")
                                        .foregroundStyle(Color.accentColor)
                                    Text(link.name).font(.headline)
                                    Spacer(minLength: 0)
                                    Text(link.createdAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    ShareLink(item: link.url(hostAccount: host)) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .buttonStyle(.bordered)
                                    Button {
                                        SecurePasteboard.copy(link.url(hostAccount: host).absoluteString)
                                        copiedId = link.id
                                    } label: {
                                        Label(copiedId == link.id ? "Copied" : "Copy",
                                              systemImage: copiedId == link.id ? "checkmark" : "doc.on.doc")
                                    }
                                    .buttonStyle(.bordered)
                                    Spacer(minLength: 0)
                                    Button {
                                        Task {
                                            if await callManager.startLinkCall(callId: link.id, name: link.name) {
                                                dismiss()
                                            }
                                        }
                                    } label: {
                                        Label("Start", systemImage: "phone.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(callManager.isInGroupCall)
                                }
                                .labelStyle(.titleAndIcon)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                            .swipeActions {
                                Button(role: .destructive) { store.delete(link.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Call Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("New Call Link", isPresented: $showingNew) {
                TextField("Name (e.g. Weekly catch-up)", text: $newName)
                Button("Create") { store.create(name: newName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The name is only shown to you.")
            }
        }
    }
}

/// Host: "X wants to join your call" with Deny / Let In.
struct LinkJoinRequestBanner: View {
    @Environment(CallManager.self) private var callManager
    let request: LinkJoinRequest

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("wants to join your call").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Deny") { callManager.denyLinkJoin(request) }
                .buttonStyle(.bordered)
            Button("Let In") { Task { await callManager.admitLinkJoin(request) } }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }
}

/// Joiner: waiting to be let in (or told no).
struct OutgoingLinkJoinCard: View {
    @Environment(CallManager.self) private var callManager
    let join: OutgoingLinkJoin

    var body: some View {
        VStack(spacing: 14) {
            switch join.status {
            case .waiting:
                ProgressView()
                Text("Waiting to be let in…").font(.headline)
                Text("We've asked \(join.hostName) to let you into the call.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Cancel", role: .cancel) { callManager.cancelLinkJoin() }
            case .denied:
                Image(systemName: "xmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("You weren't let in").font(.headline)
                Button("OK") { callManager.cancelLinkJoin() }.buttonStyle(.borderedProminent)
            case .noAnswer:
                Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                Text("No answer").font(.headline)
                Text("The host didn't respond. They may not be available right now.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("OK") { callManager.cancelLinkJoin() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
        .padding(24)
    }
}
