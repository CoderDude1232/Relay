//
//  ChatDetailView.swift
//  RelayWatch Watch App
//

import SwiftUI

struct ChatDetailView: View {
    let chatId: String

    @Environment(WatchSession.self) private var session
    @State private var errorMessage: String?
    @State private var callStarted = false

    private static let quickReplies = ["👍", "OK", "On my way", "Can't talk now", "❤️"]

    private var chat: WatchSnapshot.Chat? { session.chat(id: chatId) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    let messages = session.messages(in: chatId)
                    if messages.isEmpty {
                        Text(chat?.messages.isEmpty == false ? "" : "No recent messages")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(messages) { message in
                        WatchBubble(message: message, bubble: session.snapshot.bubble)
                            .id(message.id)
                    }
                    replyControls
                        .id("reply")
                        .padding(.top, 6)
                }
                .padding(.horizontal, 2)
            }
            .onAppear {
                proxy.scrollTo("reply", anchor: .bottom)
                session.markRead(chatId)
            }
            .onChange(of: session.messages(in: chatId).count) {
                withAnimation { proxy.scrollTo("reply", anchor: .bottom) }
            }
        }
        .navigationTitle(chat?.name ?? "Chat")
        .toolbar {
            if chat?.canCall == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await startCall() }
                    } label: {
                        Image(systemName: "phone.fill")
                    }
                    .accessibilityLabel("Call \(chat?.name ?? "")")
                }
            }
        }
        .alert("Calling on your iPhone", isPresented: $callStarted) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The call is on your iPhone. Use your iPhone or headphones to talk.")
        }
        .alert("Couldn't send", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var replyControls: some View {
        VStack(spacing: 6) {
            TextFieldLink(prompt: Text("Message")) {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    .frame(maxWidth: .infinity)
            } onSubmit: { text in
                Task { await send(text) }
            }
            .buttonStyle(.borderedProminent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button(reply) { Task { await send(reply) } }
                            .buttonStyle(.bordered)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func send(_ text: String) async {
        if let error = await session.send(text, to: chatId) { errorMessage = error }
    }

    private func startCall() async {
        if let error = await session.call(chatId, video: false) {
            errorMessage = error
        } else {
            callStarted = true
        }
    }
}

private struct WatchBubble: View {
    let message: WatchSnapshot.Message
    let bubble: String?

    var body: some View {
        if message.text.hasPrefix("call:") {
            Label(String(message.text.dropFirst("call:".count)), systemImage: "phone.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            HStack {
                if message.outgoing { Spacer(minLength: 16) }
                VStack(alignment: .leading, spacing: 1) {
                    if let sender = message.sender {
                        Text(sender)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(message.text)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(background, in: .rect(cornerRadius: 14, style: .continuous))
                .foregroundStyle(message.outgoing ? .white : .primary)
                .opacity(message.id.hasPrefix("pending-") ? 0.6 : 1)
                if !message.outgoing { Spacer(minLength: 16) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var background: AnyShapeStyle {
        guard message.outgoing else { return AnyShapeStyle(Color.white.opacity(0.16)) }
        let stops = (bubble ?? "").split(separator: "-").compactMap { Color(relayHex: String($0)) }
        let a = stops.first ?? .accentColor
        let b = stops.count > 1 ? stops[1] : a
        return AnyShapeStyle(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var accessibilityText: String {
        let who = message.outgoing ? "You" : (message.sender ?? "")
        let time = Date(timeIntervalSince1970: Double(message.timestamp) / 1000).formatted(date: .omitted, time: .shortened)
        return who.isEmpty ? "\(message.text), \(time)" : "\(who): \(message.text), \(time)"
    }
}

extension Color {
    init?(relayHex hex: String) {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
