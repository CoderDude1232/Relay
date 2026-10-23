//
//  CallsView.swift
//  Relay
//
//  Recent call history and quick call-back actions.
//

import SecureStorage
import SwiftUI

struct CallsView: View {
    /// UserDefaults key (Double, ms since epoch): missed calls at or before this
    /// instant have been seen and no longer badge the Calls tab.
    nonisolated static let missedCallsSeenAtKey = "relay.missedCallsSeenAt"

    let service: MessagingService
    @Environment(AppModel.self) private var model
    @Environment(CallManager.self) private var callManager
    @State private var showingClearConfirm = false
    @State private var showingCallLinks = false
    @AppStorage(CallsView.missedCallsSeenAtKey) private var missedCallsSeenAt: Double = 0
    @State private var missedOnly = false

    /// A row: back-to-back calls with the same person that went the same way
    /// (all missed, or all not) share one row with a count.
    struct CallGroup: Identifiable {
        var calls: [StoredCall]
        var id: String { calls[0].id }
        var latest: StoredCall { calls[0] }
    }

    /// Call history grouped into day sections, most recent first.
    private var sections: [(id: Int, title: String, groups: [CallGroup])] {
        let cal = Calendar.current
        var result: [(id: Int, title: String, groups: [CallGroup])] = []
        for call in service.callHistory where !missedOnly || call.outcome == .missed {
            let date = Date(timeIntervalSince1970: Double(call.startedAt) / 1000)
            let title = Self.sectionTitle(date, cal: cal)
            if result.last?.title != title {
                result.append((id: result.count, title: title, groups: []))
            }
            var groups = result[result.count - 1].groups
            if let last = groups.last?.latest, last.peerAccount == call.peerAccount,
               (last.outcome == .missed) == (call.outcome == .missed) {
                groups[groups.count - 1].calls.append(call)
            } else {
                groups.append(CallGroup(calls: [call]))
            }
            result[result.count - 1].groups = groups
        }
        return result
    }

    private func markMissedCallsSeen() {
        let newest = service.callHistory.map { Double($0.startedAt) }.max() ?? 0
        missedCallsSeenAt = max(missedCallsSeenAt, newest, Date().timeIntervalSince1970 * 1000)
    }

    /// The existing 1:1 chat with this call's peer, if any.
    private func conversationId(for call: StoredCall) -> String? {
        service.conversations.first { !$0.isGroup && $0.peerAccount == call.peerAccount }?.id
    }

    private func callBack(_ call: StoredCall, kind: CallKind) {
        guard case .idle = callManager.state else { return }
        Task {
            await callManager.startCall(
                peerAccount: call.peerAccount,
                peerName: service.displayName(forAccount: call.peerAccount),
                kind: kind
            )
        }
    }

    /// Opens the chat with that person via the notification-tap path (which
    /// switches to Chats); with no chat yet, calls them back.
    private func handleTap(_ call: StoredCall) {
        if let id = conversationId(for: call) {
            model.pendingNotificationConversationId = id
        } else {
            callBack(call, kind: call.kind == .video ? .video : .audio)
        }
    }

    private static func sectionTitle(_ date: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: .now), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        AdaptiveNavigation {
            Group {
                if service.callHistory.isEmpty {
                    ContentUnavailableView {
                        Label("No Calls Yet", systemImage: "phone.badge.waveform.fill")
                    } description: {
                        Text("Your voice and video calls will appear here. Start one from any chat or a contact's card.")
                    }
                } else {
                    List {
                        Picker("Show", selection: $missedOnly) {
                            Text("All").tag(false)
                            Text("Missed").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        if missedOnly && sections.isEmpty {
                            ContentUnavailableView("No Missed Calls", systemImage: "phone.badge.checkmark",
                                                   description: Text("Calls you miss will show here."))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        ForEach(sections, id: \.id) { section in
                            Section {
                                ForEach(section.groups) { group in
                                    let call = group.latest
                                    CallHistoryRow(call: call, count: group.calls.count, service: service) { kind in
                                        callBack(call, kind: kind)
                                    }
                                    .onTapGesture { handleTap(call) }
                                    .accessibilityAction(named: conversationId(for: call) != nil ? "Open chat" : "Call back") {
                                        handleTap(call)
                                    }
                                    .contextMenu {
                                        if let id = conversationId(for: call) {
                                            Button {
                                                model.pendingNotificationConversationId = id
                                            } label: {
                                                Label("Open Chat", systemImage: "bubble.left")
                                            }
                                        }
                                        Button {
                                            callBack(call, kind: .audio)
                                        } label: {
                                            Label("Audio Call", systemImage: "phone")
                                        }
                                        Button {
                                            callBack(call, kind: .video)
                                        } label: {
                                            Label("Video Call", systemImage: "video")
                                        }
                                    }
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                }
                            } header: {
                                DSSectionHeader(title: section.title)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Calls")
            .sheet(isPresented: $showingCallLinks) { CallLinksView(service: service) }
            .onAppear {
                service.refreshCallHistory()
                markMissedCallsSeen()
            }
            .toolbar {
                if !service.isDemoAccount {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingCallLinks = true } label: {
                            Label("Call Links", systemImage: "link")
                        }
                    }
                }
                if !service.callHistory.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { showingClearConfirm = true }
                            .foregroundStyle(.red)
                    }
                }
            }
            .confirmationDialog("Clear call history?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    service.clearCallHistory()
                }
                Button("Cancel", role: .cancel) {}
            }
        } placeholder: {
            CallsPlaceholder(service: service)
        }
    }
}

private struct CallHistoryRow: View {
    let call: StoredCall
    /// Back-to-back calls this row stands for.
    var count = 1
    let service: MessagingService
    let onCall: (CallKind) -> Void

    private var displayName: String {
        service.displayName(forAccount: call.peerAccount)
    }

    private var avatarData: Data? {
        service.peerAvatarData(forAccount: call.peerAccount)
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: displayName, size: 48, imageData: avatarData)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(call.outcome == .missed ? .headline.weight(.bold) : .headline)
                        .lineLimit(1)
                    if count > 1 {
                        Text("(\(count))")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(count) calls")
                    }
                    if call.outcome == .missed {
                        Label("Missed", systemImage: "phone.down.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red, in: .capsule)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: directionSymbol)
                        .font(.caption)
                        .foregroundStyle(outcomeTint)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(isNegative ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(Date(timeIntervalSince1970: Double(call.startedAt) / 1000)
                        .formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    callActionButton(systemName: "phone.fill") { onCall(.audio) }
                    callActionButton(systemName: "video.fill") { onCall(.video) }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func callActionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .glassCompat(in: .circle)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(systemName == "phone.fill" ? "Audio call" : "Video call")
    }

    private var directionSymbol: String {
        switch call.direction {
        case .incoming: return call.outcome == .missed ? "phone.down.fill" : "phone.arrow.down.left.fill"
        case .outgoing: return "phone.arrow.up.right.fill"
        }
    }

    private var outcomeTint: Color {
        switch call.outcome {
        case .answered: return .secondary
        case .missed, .failed: return .red
        case .declined: return .orange
        }
    }

    private var isNegative: Bool {
        call.outcome == .missed || call.outcome == .failed
    }

    private var summary: String {
        let kind = call.kind == .video ? "Video" : "Audio"
        switch call.outcome {
        case .answered:
            if let duration = durationLabel {
                return "\(kind) call, \(duration)"
            }
            return "\(kind) call"
        case .missed:
            return "Missed \(kind.lowercased()) call"
        case .declined:
            return "Declined \(kind.lowercased()) call"
        case .failed:
            return "Failed \(kind.lowercased()) call"
        }
    }

    private var durationLabel: String? {
        guard let connected = call.connectedAt, let ended = call.endedAt, ended > connected else { return nil }
        let s = Int((ended - connected) / 1000)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

}

/// Beside the call list on iPad.
private struct CallsPlaceholder: View {
    let service: MessagingService
    @State private var showingCallLinks = false

    var body: some View {
        ContentUnavailableView {
            Label("Call Links", systemImage: "link")
        } description: {
            Text("Share a link to start a group call with anyone on Relay.")
        } actions: {
            if !service.isDemoAccount {
                Button("Open Call Links") { showingCallLinks = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $showingCallLinks) { CallLinksView(service: service) }
    }
}
