//
//  PollViews.swift
//  Relay
//

import RelayCore
import RelayKit
import SecureStorage
import SwiftUI

// MARK: - Poll composer

struct PollComposerSheet: View {
    let onSend: (String, [String], Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var multiSelect = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Ask something…", text: $question, axis: .vertical)
                        .lineLimit(3)
                }

                Section("Options") {
                    ForEach(options.indices, id: \.self) { i in
                        HStack {
                            TextField("Option \(i + 1)", text: $options[i])
                                .onChange(of: options[i]) { _, v in
                                    if v.count > 80 { options[i] = String(v.prefix(80)) }
                                }
                            if !options[i].isEmpty {
                                Text("\(options[i].count)/80")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(options[i].count > 70 ? .orange : .secondary)
                            }
                            if options.count > 2 {
                                Button(role: .destructive) { options.remove(at: i) } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .accessibilityLabel("Remove option")
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if options.count < 10 {
                        Button {
                            options.append("")
                        } label: {
                            Label("Add Option", systemImage: "plus.circle")
                        }
                    }
                }

                Section("Settings") {
                    Toggle("Allow multiple choices", isOn: $multiSelect)
                }
            }
            .navigationTitle("New Poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let trimmed = options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        onSend(question.trimmingCharacters(in: .whitespaces), trimmed, multiSelect)
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
        }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty
        && options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
    }
}

// MARK: - Poll bubble

private let pollPrefix = "__poll__:"

struct PollBubble: View {
    let message: StoredMessage
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool

    @State private var votes: [StoredPollVote] = []
    @State private var mySelections: Set<Int> = []

    private var payload: PollPayload? {
        let json = message.body.hasPrefix(pollPrefix)
            ? String(message.body.dropFirst(pollPrefix.count))
            : message.body
        return PollPayload.decode(json)
    }

    /// Older polls stored the bare question instead of JSON.
    private var question: String {
        payload?.question ?? String(message.body.dropFirst(message.body.hasPrefix(pollPrefix) ? pollPrefix.count : 0))
    }

    private var pollAuthor: String {
        isOutgoing ? service.credentials.accountId : (message.senderAccount ?? "")
    }

    private var pollTimestamp: Int64 { message.timestamp }

    private var options: [String] {
        parsePollOptions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Poll")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Poll")
            Text(question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        PollOptionRow(
                            label: opt,
                            voteCount: votes.filter { $0.selectedOptions.contains(idx) }.count,
                            totalVotes: votes.isEmpty ? 0 : uniqueVoters,
                            isSelected: mySelections.contains(idx),
                            isOutgoing: false  // drawn on a neutral card, not the tinted bubble
                        ) {
                            castVote(for: idx)
                        }
                    }
                }
            }

            let voterCount = uniqueVoters
            Text(voterCount == 0 ? "No votes yet" : "\(voterCount) vote\(voterCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { refresh() }
        .onChange(of: service.activeMessages.count) { refresh() }
    }

    private var uniqueVoters: Int {
        Set(votes.map { $0.voterAccount }).count
    }

    private func refresh() {
        votes = service.pollVotes(conversationId: conversationId, pollAuthor: pollAuthor, pollTimestamp: pollTimestamp)
        let mine = votes.filter { $0.voterAccount == service.credentials.accountId }
        mySelections = Set(mine.flatMap { $0.selectedOptions })
    }

    private func castVote(for idx: Int) {
        var newSelections: [Int]
        if payload?.multiSelect == true {
            var set = mySelections
            if set.contains(idx) { set.remove(idx) } else { set.insert(idx) }
            newSelections = set.sorted()
        } else if mySelections.contains(idx) {
            newSelections = []
        } else {
            newSelections = [idx]
        }
        mySelections = Set(newSelections)
        Task {
            await service.sendPollVote(
                pollAuthor: pollAuthor,
                pollTimestamp: pollTimestamp,
                selectedOptions: newSelections,
                in: conversationId
            )
            refresh()
        }
    }

    private func parsePollOptions() -> [String] {
        payload?.options ?? []
    }
}

private struct PollOptionRow: View {
    let label: String
    let voteCount: Int
    let totalVotes: Int
    let isSelected: Bool
    let isOutgoing: Bool
    let onTap: () -> Void

    private var fraction: Double {
        guard totalVotes > 0 else { return 0 }
        return Double(voteCount) / Double(totalVotes)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                // Background bar
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOutgoing ? Color.white.opacity(0.15) : Color.primary.opacity(0.08))

                // Fill bar
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected
                            ? (isOutgoing ? Color.white.opacity(0.4) : Color.accentColor.opacity(0.25))
                            : (isOutgoing ? Color.white.opacity(0.2) : Color.primary.opacity(0.12))
                        )
                        .frame(width: geo.size.width * fraction)
                        .animation(.easeInOut(duration: 0.3), value: fraction)
                }

                HStack {
                    HStack(spacing: 6) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(isOutgoing ? .white : .accentColor)
                        }
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(isOutgoing ? .white : .primary)
                    }
                    Spacer()
                    if totalVotes > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(fraction * 100))%")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isOutgoing ? .white.opacity(0.9) : .primary)
                            Text("\(voteCount)/\(totalVotes)")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(isOutgoing ? .white.opacity(0.5) : .secondary)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 36)
        }
        .buttonStyle(.plain)
    }
}
