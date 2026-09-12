//
//  CallsView.swift
//  Relay
//
//  Recent call history and quick call-back actions.
//

import SecureStorage
import SwiftUI

struct CallsView: View {
    let service: MessagingService
    @Environment(CallManager.self) private var callManager
    @State private var showingClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if service.callHistory.isEmpty {
                    ContentUnavailableView(
                        "No Calls",
                        systemImage: "phone",
                        description: Text("Voice and video calls will appear here.")
                    )
                } else {
                    List(service.callHistory) { call in
                        CallHistoryRow(call: call, service: service) { kind in
                            guard case .idle = callManager.state else { return }
                            Task {
                                await callManager.startCall(
                                    peerAccount: call.peerAccount,
                                    peerName: service.displayName(forAccount: call.peerAccount),
                                    kind: kind
                                )
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Calls")
            .onAppear { service.refreshCallHistory() }
            .toolbar {
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
        }
    }
}

private struct CallHistoryRow: View {
    let call: StoredCall
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
                        .foregroundStyle(call.outcome == .missed ? .primary : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(relativeLabel(call.startedAt))
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

    private func relativeLabel(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
