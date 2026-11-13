//
//  GroupViews.swift
//  Relay
//
//  Group creation and management UI, driving MessagingService.
//

import PhotosUI
import RelayKit
import SecureStorage
import SwiftUI

/// Name a new group and pick members from existing 1:1 chats or by username.
struct NewGroupView: View {
    /// Pushed inside another navigation stack (no stack or Cancel of its own).
    var embedded = false
    let service: MessagingService
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: [String] = [""]
    /// Peer accounts picked from existing 1:1 chats.
    @State private var pickedAccounts: Set<String> = []
    @State private var creating = false
    @State private var error: String?

    /// 1:1 chats whose peer has a known username (createGroup resolves members
    /// by username), excluding Note to Self, the Relay chat and blocked contacts.
    private struct ChatCandidate: Identifiable {
        let account: String
        let username: String
        let name: String
        var id: String { account }
    }

    private var chatCandidates: [ChatCandidate] {
        var seen = Set<String>()
        return service.conversations.compactMap { c in
            guard !c.isGroup,
                  c.peerAccount != service.noteToSelfAccount,
                  c.peerAccount != service.relayOfficialAccount,
                  !service.isBlocked(c.peerAccount),
                  seen.insert(c.peerAccount).inserted,
                  let username = service.username(forAccount: c.peerAccount),
                  !username.isEmpty
            else { return nil }
            return ChatCandidate(
                account: c.peerAccount,
                username: username,
                name: service.displayName(forAccount: c.peerAccount)
            )
        }
    }

    var body: some View {
        OptionalNavigationStack(enabled: !embedded) {
            Form {
                Section {
                    SettingsHero(systemName: "person.3.fill", color: .orange, title: "New Group",
                                 message: "Name it, then pick people from your chats or add them by username.")
                        .settingsBareRow()
                }
                Section("Group name") {
                    TextField("e.g. Family, Book Club", text: $name).incognitoKeyboard()
                        .accessibilityLabel("Group name")
                }
                let candidates = chatCandidates
                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { candidate in
                            let picked = pickedAccounts.contains(candidate.account)
                            Button {
                                if picked {
                                    pickedAccounts.remove(candidate.account)
                                } else {
                                    pickedAccounts.insert(candidate.account)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(
                                        name: candidate.name,
                                        size: 32,
                                        imageData: service.peerAvatarData(forAccount: candidate.account)
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.name).foregroundStyle(.primary)
                                        Text("@\(candidate.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                                        .font(.title3)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
                        }
                    } header: {
                        Text("From your chats")
                    } footer: {
                        if !pickedAccounts.isEmpty {
                            Text("\(pickedAccounts.count) selected")
                        }
                    }
                }
                Section {
                    ForEach(members.indices, id: \.self) { index in
                        TextField("@username", text: $members[index])
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Button { members.append("") } label: {
                        Label {
                            Text("Add Another Username").foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("Add by Username")
                } footer: {
                    Text("Someone not on Relay yet? After you create the group, open Add Members to send them a link.")
                }
                Section {
                    SettingsPrimaryButton(title: "Create Group", color: .orange, working: creating) { create() }
                        .disabled(!canCreate)
                        .settingsBareRow()
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if !canCreate {
                        Text(name.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Give the group a name to continue."
                             : "Add at least one person to continue.")
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .navigationBarBackButtonHidden(creating)
        }
    }

    private var typedUsernames: [String] {
        // The field shows "@username", so people often type the @ too.
        members
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
            .filter { !$0.isEmpty }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (!typedUsernames.isEmpty || !pickedAccounts.isEmpty)
    }

    private func create() {
        let typed = typedUsernames
        let candidates = chatCandidates
        let picked = candidates
            .filter { pickedAccounts.contains($0.account) }
            .map { $0.username }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            // Resolve typed usernames one by one so a typo can be reported by name.
            var missing: [String] = []
            for username in typed {
                do {
                    _ = try await service.resolveAccount(username: username)
                } catch RelayAPIError.http(status: 404, _) {
                    missing.append(username)
                } catch {
                    self.error = "Couldn't create the group: \(FriendlyError.message(for: error))"
                    return
                }
            }
            if !missing.isEmpty {
                let list = missing.map { "@\($0)" }.joined(separator: ", ")
                self.error = missing.count == 1
                    ? "\(list) isn't on Relay. Check the username and try again."
                    : "These usernames aren't on Relay: \(list). Check them and try again."
                return
            }
            var seen = Set<String>()
            let usernames = (picked + typed).filter { seen.insert($0.lowercased()).inserted }
            do {
                let conversationId = try await service.createGroup(
                    name: name.trimmingCharacters(in: .whitespaces),
                    memberUsernames: usernames
                )
                dismiss()
                onCreated(conversationId)
            } catch {
                self.error = "Couldn't create the group: \(FriendlyError.message(for: error))"
            }
        }
    }
}

struct GroupInfoView: View {
    let service: MessagingService
    let conversationId: String
    let ownAccountId: String
    var onActivateSearch: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(CallManager.self) private var callManager
    @State private var editingName = false
    @State private var draftName = ""
    @State private var editingDescription = false
    @State private var draftDescription = ""
    @State private var confirmingInviteReset = false
    @State private var showingAvatarPicker = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var descriptionExpanded = false
    @State private var confirmLeave = false
    /// Member being reported.
    @State private var reportTarget: ReportTarget?

    private struct ReportTarget: Identifiable, Hashable {
        let account: String
        var id: String { account }
    }
    @State private var memberToRemove: String?

    private var group: StoredGroup? { service.group(for: conversationId) }

    /// Matches MessagingService.requireGroupAdmin: groups with no recorded
    /// admins are open to every member.
    private var isAdmin: Bool {
        guard let group else { return false }
        return MessagingService.isGroupAdmin(ownAccountId, in: group)
    }

    private var conversation: Conversation? {
        service.conversations.first { $0.id == conversationId }
    }

    var body: some View {
        NavigationStack {
            List {
                if let group {
                    Section {
                        InfoHeader(name: group.name, subtitle: "\(group.members.count) members") {
                            if isAdmin {
                                Button {
                                    showingAvatarPicker = true
                                } label: {
                                    GroupAvatarView(data: group.avatarData, name: group.name, size: 104)
                                        .overlay(alignment: .bottomTrailing) {
                                            AvatarEditBadge(systemImage: "pencil", diameter: 30)
                                                .offset(x: 2, y: 2)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Change group photo")
                            } else {
                                GroupAvatarView(data: group.avatarData, name: group.name, size: 104)
                                    .accessibilityHidden(true)
                            }
                        } accessory: {
                            if isAdmin {
                                Button {
                                    draftName = group.name
                                    editingName = true
                                } label: {
                                    Image(systemName: "pencil.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Rename group")
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        let muted = service.isConversationMuted(conversationId)
                        let others = group.members.filter { $0 != ownAccountId }
                        HStack(spacing: 10) {
                            InfoQuickAction(icon: "phone.fill", label: "Voice",
                                            isDisabled: callManager.isInGroupCall || others.isEmpty) {
                                dismiss()
                                Task {
                                    await callManager.startGroupCall(groupId: group.id, groupName: group.name,
                                                                     participants: others, kind: .audio)
                                }
                            }
                            InfoQuickAction(icon: "video.fill", label: "Video",
                                            isDisabled: callManager.isInGroupCall || others.isEmpty) {
                                dismiss()
                                Task {
                                    await callManager.startGroupCall(groupId: group.id, groupName: group.name,
                                                                     participants: others, kind: .video)
                                }
                            }
                            InfoQuickAction(icon: muted ? "bell.fill" : "bell.slash.fill",
                                            label: muted ? "Unmute" : "Mute") {
                                service.setConversationMuted(conversationId, muted: !muted)
                            }
                            if let onActivateSearch {
                                InfoQuickAction(icon: "magnifyingglass", label: "Search") {
                                    dismiss()
                                    onActivateSearch()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        SharedMediaRow(service: service, conversationId: conversationId)
                    }

                    // Members who can't edit don't see an empty box.
                    if isAdmin || !group.description.isEmpty {
                    Section("Description") {
                        if group.description.isEmpty {
                            Button("Add a description…") {
                                draftDescription = ""
                                editingDescription = true
                            }
                            .tint(.primary)
                            .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Text(group.description)
                                        .foregroundStyle(.primary)
                                        .lineLimit(descriptionExpanded ? nil : 3)
                                    Spacer()
                                    if isAdmin {
                                        Button {
                                            draftDescription = group.description
                                            editingDescription = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .foregroundStyle(.blue)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Edit description")
                                    }
                                }
                                if group.description.count > 80 {
                                    Button(descriptionExpanded ? "Read Less" : "Read More") {
                                        withAnimation { descriptionExpanded.toggle() }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    }

                    // Admin-only. Picking from chats, a username, or a link for
                    // people not on Relay yet all live on one page.
                    if isAdmin {
                        Section {
                            NavigationLink {
                                AddGroupMembersView(service: service, groupId: group.id, conversationId: conversationId)
                            } label: {
                                SettingsNavRow(systemName: "person.badge.plus", color: .green, title: "Add Members")
                            }
                            if !service.isDemoAccount {
                                Button(role: .destructive) {
                                    confirmingInviteReset = true
                                } label: {
                                    SettingsNavRow(systemName: "arrow.clockwise", color: .red, title: "Reset Invite Link")
                                }
                                .tint(.red)
                                .foregroundStyle(.red)
                            }
                        }
                        .confirmationDialog("Reset the invite link?", isPresented: $confirmingInviteReset, titleVisibility: .visible) {
                            Button("Reset Link", role: .destructive) {
                                run { try await service.resetGroupInviteLink(groupId: group.id) }
                            }
                        } message: {
                            Text("Links you've shared stop working. Anyone who joined already stays in the group.")
                        }
                    }

                    Section("Chat") {
                        if let conversation {
                            NavigationLink {
                                ChatPrivacySettingsView(service: service, conversation: conversation)
                            } label: {
                                SettingsNavRow(systemName: "slider.horizontal.3", color: .blue, title: "Chat Settings")
                            }
                        }
                        NavigationLink {
                            AppearanceSettingsView(chatId: conversationId)
                        } label: {
                            SettingsNavRow(systemName: "paintbrush.fill", color: .purple, title: "Chat Appearance")
                        }
                    }

                    if group.admins.contains(ownAccountId) || group.isAnnounceOnly {
                        Section("Permissions") {
                            SettingsToggleRow(systemName: "megaphone.fill", color: .orange, title: "Announce Only", isOn: Binding(
                                get: { group.isAnnounceOnly },
                                set: { newVal in run { try await service.setAnnounceOnly(newVal, in: group.id) } }
                            ))
                            .disabled(!group.admins.contains(ownAccountId))
                        }
                    }

                    Section {
                        ForEach(group.members, id: \.self) { member in
                            let memberIsAdmin = group.admins.contains(member)
                            HStack(spacing: 12) {
                                // Our own row: our photo and initial, not the "You" label's.
                                AvatarView(
                                    name: member == ownAccountId ? (service.myDisplayName ?? service.username ?? "")
                                        : service.displayName(forAccount: member),
                                    size: 36,
                                    imageData: member == ownAccountId ? service.myAvatarData : service.peerAvatarData(forAccount: member)
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(service.displayName(forAccount: member))
                                        if memberIsAdmin {
                                            Image(systemName: "crown.fill")
                                                .font(.caption)
                                                .foregroundStyle(.yellow)
                                                .accessibilityLabel("Admin")
                                        }
                                    }
                                    if let username = member == ownAccountId ? service.username : service.username(forAccount: member) {
                                        Text("@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isAdmin && member != ownAccountId {
                                    Button(role: .destructive) {
                                        memberToRemove = member
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(service.displayName(forAccount: member))")
                                }
                            }
                            .contextMenu {
                                if isAdmin && member != ownAccountId {
                                    if memberIsAdmin {
                                        Button(role: .destructive) {
                                            run { try await service.demoteAdmin(in: group.id, account: member) }
                                        } label: {
                                            Label("Remove Admin", systemImage: "crown.slash")
                                        }
                                    } else {
                                        Button {
                                            run { try await service.promoteAdmin(in: group.id, account: member) }
                                        } label: {
                                            Label("Make Admin", systemImage: "crown")
                                        }
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        memberToRemove = member
                                    } label: {
                                        Label("Remove from Group", systemImage: "person.badge.minus")
                                    }
                                }
                                if member != ownAccountId {
                                    Button(role: .destructive) {
                                        reportTarget = ReportTarget(account: member)
                                    } label: {
                                        Label("Report…", systemImage: "exclamationmark.bubble")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Members (\(group.members.count))")
                    } footer: {
                        if !isAdmin { Text("Only admins can change the group's name, photo and members.") }
                    }


                    Section {
                        // Reports the group's admins; individual members are
                        // reported from their row's menu.
                        if let admin = group.admins.first(where: { $0 != ownAccountId }) {
                            Button {
                                reportTarget = ReportTarget(account: admin)
                            } label: {
                                SettingsNavRow(systemName: "exclamationmark.bubble.fill", color: .red, title: "Report Group")
                            }
                            .tint(.red)
                            .foregroundStyle(.red)
                        }
                        Button {
                            confirmLeave = true
                        } label: {
                            SettingsNavRow(systemName: "rectangle.portrait.and.arrow.right", color: .red, title: "Leave Group")
                        }
                        .tint(.red)
                        .foregroundStyle(.red)
                    } footer: {
                        Text("Touch and hold a member to report them. Reports go to the Relay team; messages are included only if you choose.")
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }
                } else {
                    Text("This group isn't available anymore.")
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The header names the group, like the contact card.
                ToolbarItem(placement: .principal) { Text(verbatim: " ").accessibilityHidden(true) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if working { ProgressView() } }
            .alert("Rename Group", isPresented: $editingName) {
                TextField("Name", text: $draftName).incognitoKeyboard()
                Button("Save") {
                    guard let group else { return }
                    let name = draftName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    run { try await service.renameGroup(groupId: group.id, name: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Group Description", isPresented: $editingDescription) {
                TextField("Description", text: $draftDescription).incognitoKeyboard()
                Button("Save") {
                    guard let group else { return }
                    run { try await service.setGroupDescription(draftDescription, groupId: group.id) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(item: $reportTarget) { target in
                ReportContactSheet(
                    service: service, account: target.account,
                    displayName: service.displayName(forAccount: target.account),
                    embedded: true
                )
            }
            .sheet(isPresented: $showingAvatarPicker) {
                if let group {
                    GroupAvatarPickerSheet(service: service, groupId: group.id)
                }
            }
            .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave Group", role: .destructive) {
                    run(dismissAfter: true) { try await service.leaveGroup(group?.id ?? "") }
                }
            }
            .confirmationDialog(
                "Remove \(memberToRemove.flatMap { service.displayName(forAccount: $0) }.map { "\($0) from the group?" } ?? "member from the group?")",
                isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let m = memberToRemove, let gid = group?.id {
                        run { try await service.removeGroupMember(m, fromGroup: gid) }
                    }
                    memberToRemove = nil
                }
            }
        }
    }

    private func run(dismissAfter: Bool = false, _ action: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            do {
                try await action()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
            // On failure, stay open so the error is visible.
            if dismissAfter && errorMessage == nil { dismiss() }
        }
    }
}

// MARK: - Group avatar display

// MARK: - Add members

/// Adds people to a group three ways: tick them from your chats, type a
/// username, or send the group's invite link, which also works for someone
/// who doesn't have Relay yet (it carries through installing and signing up).
struct AddGroupMembersView: View {
    let service: MessagingService
    let groupId: String
    let conversationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var username = ""
    @State private var query = ""
    @State private var working = false
    @State private var sharing = false
    @State private var inviteURL: URL?
    @State private var errorMessage: String?

    private struct Candidate: Identifiable {
        let account: String
        let username: String
        let name: String
        var id: String { account }
    }

    /// 1:1 chats with a known username who aren't in the group yet.
    private var candidates: [Candidate] {
        let members = Set(service.group(for: conversationId)?.members ?? [])
        var seen = Set<String>()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return service.conversations.compactMap { c in
            guard !c.isGroup,
                  c.peerAccount != service.noteToSelfAccount,
                  c.peerAccount != service.relayOfficialAccount,
                  !members.contains(c.peerAccount),
                  !service.isBlocked(c.peerAccount),
                  seen.insert(c.peerAccount).inserted,
                  let username = service.username(forAccount: c.peerAccount), !username.isEmpty
            else { return nil }
            let name = service.displayName(forAccount: c.peerAccount)
            guard q.isEmpty || name.lowercased().contains(q) || username.lowercased().contains(q) else { return nil }
            return Candidate(account: c.peerAccount, username: username, name: name)
        }
    }

    private var typedUsername: String {
        username.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    private var addCount: Int { picked.count + (typedUsername.isEmpty ? 0 : 1) }

    var body: some View {
        Form {
            Section {
                SettingsHero(systemName: "person.badge.plus", color: .green, title: "Add Members",
                             message: "Pick people you chat with, or add someone by username. Not on Relay yet? Send them a link.")
                    .settingsBareRow()
            }

            if !service.isDemoAccount {
                Section {
                    Button { shareInviteLink() } label: {
                        SettingsNavRow(systemName: "link.badge.plus", color: .blue, title: "Invite with a Link")
                    }
                    .tint(.primary)
                    .disabled(working)
                } footer: {
                    Text("Anyone with the link can join, even if they don't have Relay yet.")
                }
            }

            let candidates = candidates
            if !candidates.isEmpty || !query.isEmpty {
                Section("Your Chats") {
                    ForEach(candidates) { candidate in
                        let isPicked = picked.contains(candidate.account)
                        Button {
                            if isPicked { picked.remove(candidate.account) } else { picked.insert(candidate.account) }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: candidate.name, size: 36,
                                           imageData: service.peerAvatarData(forAccount: candidate.account))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.name).foregroundStyle(.primary)
                                    Text("@\(candidate.username)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
                    }
                    if candidates.isEmpty {
                        Text("No chats match.").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { add() }
                }
            } header: {
                Text("Add by Username")
            } footer: {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                SettingsPrimaryButton(title: addCount > 1 ? "Add \(addCount) People" : "Add to Group",
                                      color: .green, working: working) { add() }
                    .disabled(addCount == 0)
                    .settingsBareRow()
            }
        }
        .modifier(ThemedPageBackground())
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search your chats")
        .navigationTitle("Add Members")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(working)
        .sheet(isPresented: $sharing) {
            if let inviteURL { ShareSheet(items: [inviteURL]) }
        }
    }

    private func add() {
        guard addCount > 0, !working else { return }
        let usernames = picked.compactMap { service.username(forAccount: $0) } + (typedUsername.isEmpty ? [] : [typedUsername])
        working = true
        errorMessage = nil
        Task {
            var failed: [String] = []
            for name in usernames {
                do {
                    try await service.addGroupMember(username: name, toGroup: groupId)
                } catch {
                    failed.append(name)
                    errorMessage = FriendlyError.message(for: error)
                }
            }
            working = false
            if failed.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } else {
                // Keep only what didn't go through, so Add retries just those.
                picked = picked.filter { service.username(forAccount: $0).map(failed.contains) ?? false }
                if !failed.contains(typedUsername) { username = "" }
                if failed.count > 1 || errorMessage == nil {
                    errorMessage = "Couldn't add " + failed.map { "@" + $0 }.joined(separator: ", ") + "."
                }
            }
        }
    }

    private func shareInviteLink() {
        working = true
        errorMessage = nil
        Task {
            do {
                inviteURL = URL(string: try await service.createGroupInviteLink(groupId: groupId))
                sharing = inviteURL != nil
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}

struct GroupAvatarView: View {
    let data: Data?
    let name: String
    let size: CGFloat

    /// The same initial and colour as the group's row in the chat list.
    var body: some View {
        AvatarView(name: name, size: size, imageData: data)
    }
}

// MARK: - Avatar picker sheet

private struct GroupAvatarPickerSheet: View {
    let service: MessagingService
    let groupId: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var photoToCrop: CropImageItem?
    @State private var working = false
    @State private var uploadError: String?

    var body: some View {
        NavigationStack {
            PhotosPicker(
                selection: $selectedItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                ContentUnavailableView("Choose a Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Group Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = SafeImage.image(from: data, maxPixelSize: 3000) {
                        photoToCrop = CropImageItem(image: image)
                    } else {
                        uploadError = "Couldn't open that photo."
                    }
                }
            }
            .fullScreenCover(item: $photoToCrop) { item in
                AvatarCropView(image: item.image) {
                    photoToCrop = nil
                    selectedItem = nil
                } onChoose: { cropped in
                    photoToCrop = nil
                    upload(cropped)
                }
            }
            .overlay { if working { ProgressView() } }
            .alert("Photo Upload Failed", isPresented: Binding(
                get: { uploadError != nil },
                set: { if !$0 { uploadError = nil } }
            )) {
                Button("OK", role: .cancel) { uploadError = nil }
            } message: {
                Text(uploadError ?? "")
            }
        }
    }

    private func upload(_ image: UIImage) {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        working = true
        uploadError = nil
        Task {
            do {
                try await service.setGroupAvatar(jpeg, groupId: groupId)
                dismiss()
            } catch {
                uploadError = error.localizedDescription
            }
            working = false
        }
    }
}


/// A NavigationStack only when the view isn't already inside one.
struct OptionalNavigationStack<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if enabled {
            NavigationStack { content }
        } else {
            content
        }
    }
}
