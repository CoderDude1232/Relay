//
//  ChatSupportViews.swift
//  Relay
//
//  System messages, typing, forwarding, message info, bubble chrome,
//  location and notepad bubbles, and the chat's smaller sheets. Split out of
//  ChatView.swift.
//

import CoreLocation
import Foundation
import MapKit
import OSLog
import PhotosUI
import RelayKit
import SecureStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

import SafariServices

// MARK: - System messages and typing indicator

// Bodies prefixed with "call:" get a phone symbol; others render as plain caption text.
struct SystemMessageView: View {
    let rawBody: String

    private var isCallMessage: Bool { rawBody.hasPrefix("call:") }
    private var displayText: String {
        isCallMessage ? String(rawBody.dropFirst("call:".count)) : rawBody
    }
    private var callIcon: String {
        let t = displayText.lowercased()
        if t.hasPrefix("missed") { return "phone.arrow.down.left.fill" }
        if t.hasPrefix("outgoing") { return "phone.arrow.up.right.fill" }
        return "phone.fill"
    }

    var body: some View {
        Group {
            if isCallMessage {
                HStack(spacing: 4) {
                    Image(systemName: callIcon)
                    Text(displayText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TypingIndicatorView: View {
    let peerName: String
    var imageData: Data? = nil
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            AvatarView(name: peerName, size: 28, imageData: imageData)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 7, height: 7)
                        .foregroundStyle(.secondary)
                        .opacity(phase == index ? 1 : 0.35)
                        .offset(y: phase == index && !reduceMotion ? -4 : 0)
                        .animation(.spring(duration: 0.3, bounce: 0.5).delay(Double(index) * 0.05), value: phase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.fill.secondary, in: .rect(cornerRadius: DS.Radius.bubble))
            Spacer(minLength: 56)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(peerName) is typing")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                phase = (phase + 1) % 3
            }
        }
    }
}




struct ForwardPayload: Identifiable {
    let id = UUID()
    let messages: [StoredMessage]
}

struct ForwardMessageSheet: View {
    let payload: ForwardPayload
    let service: MessagingService

    @Environment(\.dismiss) private var dismiss
    @State private var isSending = false

    private var conversations: [Conversation] {
        service.conversations.filter { !$0.archived }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a conversation first.")
                    )
                } else {
                    List(conversations) { conv in
                        Button { forward(to: conv.id) } label: {
                            let convName = conv.isGroup
                                ? (conv.peerUsername ?? "Group")
                                : service.displayName(forAccount: conv.peerAccount)
                            let avatarImg = conv.isGroup
                                ? service.group(for: conv.id)?.avatarData
                                : service.peerAvatarData(forAccount: conv.peerAccount)
                            HStack(spacing: 12) {
                                AvatarView(name: convName, size: 44, imageData: avatarImg)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(convName)
                                        .font(.body.weight(.medium))
                                    if !conv.isGroup, let username = conv.peerUsername {
                                        Text("@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(isSending)
                    }
                }
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay { if isSending { ProgressView() } }
        }
    }

    private func forward(to conversationId: String) {
        guard !isSending else { return }
        isSending = true
        Task {
            for message in payload.messages {
                await service.forward(message, to: conversationId)
            }
            dismiss()
        }
    }
}

struct MessageInfoView: View {
    let message: StoredMessage
    let isOwnAuthor: Bool
    let peerName: String
    var service: MessagingService? = nil
    var conversationId: String? = nil
    var isGroup: Bool = false

    private var groupReceipts: [(name: String, status: String)] {
        guard isGroup, message.isOutgoing, let service, let conversationId else { return [] }
        return service.groupReadReceipts(for: message, in: conversationId)
    }

    var body: some View {
        List {
            LabeledContent("From", value: isOwnAuthor ? "You" : peerName)
            LabeledContent("Sent", value: fullTimestamp)
            if message.isOutgoing, !isGroup {
                LabeledContent("Status", value: statusLabel)
            }
            if !groupReceipts.isEmpty {
                Section("Read by \(groupReceipts.filter { $0.status == "Read" }.count) of \(groupReceipts.count)") {
                    ForEach(groupReceipts, id: \.name) { receipt in
                        LabeledContent(receipt.name, value: receipt.status)
                    }
                }
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fullTimestamp: String {
        Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
            .formatted(date: .abbreviated, time: .standard)
    }

    private var statusLabel: String {
        switch message.status {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read: "Read"
        case .failed: "Failed"
        case .received: "Received"
        }
    }
}

// MARK: - Bubble chrome

struct BubbleChrome: ViewModifier {
    let isOutgoing: Bool
    let cornerRadii: RectangleCornerRadii
    let appearance: ChatAppearance

    func body(content: Content) -> some View {
        content
            .background(
                isOutgoing ? AnyShapeStyle(appearance.bubbleGradient) : AnyShapeStyle(Color(.systemBackground).opacity(0.92)),
                in: .rect(cornerRadii: cornerRadii)
            )
            .overlay {
                if !isOutgoing {
                    UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
                }
            }
            .shadow(
                color: isOutgoing ? appearance.bubbleTint.opacity(0.30) : .black.opacity(0.05),
                radius: 5, x: 0, y: 2
            )
            .foregroundStyle(isOutgoing ? .white : .primary)
    }
}

/// Plain card (white in light mode, black in dark) for maps and polls.
struct NeutralCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.systemBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 5, x: 0, y: 2)
            .foregroundStyle(.primary)
    }
}

// MARK: - Location bubble

struct LocationBubble: View {
    let payload: LocationPayload
    let isOutgoing: Bool
    let footer: AnyView

    @State private var position: MapCameraPosition

    init(payload: LocationPayload, isOutgoing: Bool, footer: AnyView) {
        self.payload = payload
        self.isOutgoing = isOutgoing
        self.footer = footer
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng),
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )))
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng)
    }

    private func recenter() {
        withAnimation(.easeInOut(duration: 0.5)) {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
        }
    }

    /// Received locations don't load map tiles until the user asks: fetching
    /// tiles tells Apple's map servers, with our IP, where the sender is.
    @State private var mapRevealed = false
    @State private var showingFullMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isOutgoing || mapRevealed {
                Map(position: $position) {
                    Marker("", coordinate: coordinate)
                        .tint(.red)
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(true)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(7)
                        .background(.regularMaterial, in: .circle)
                        .padding(6)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { showingFullMap = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the map full screen")
                // Recenter as a live share moves.
                .onChange(of: payload.lat) { _, _ in recenter() }
                .onChange(of: payload.lng) { _, _ in recenter() }
            } else {
                Button {
                    mapRevealed = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "map.fill")
                            .font(.title2)
                        Text("Tap to show map")
                            .font(.caption.weight(.semibold))
                        Text("Loads map tiles from Apple Maps")
                            .font(.caption2)
                            .opacity(0.7)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shared location. Tap to show map.")
            }

            HStack(spacing: 4) {
                Image(systemName: payload.stop || payload.isExpired ? "location.slash.fill" : "location.fill")
                    .font(.caption)
                Text(payload.stop ? "Stopped sharing"
                     : payload.isExpired ? "Location expired"
                     : "Live location")
                    .font(.caption)
                Spacer(minLength: 8)
                footer
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 240)
        .fullScreenCover(isPresented: $showingFullMap) {
            // Re-evaluated as the bubble re-renders, so a live share keeps moving.
            FullScreenLocationView(payload: payload)
        }
    }
}

/// Full-screen map for a shared or live location.
struct FullScreenLocationView: View {
    let payload: LocationPayload
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var following = true

    init(payload: LocationPayload) {
        self.payload = payload
        _position = State(initialValue: Self.region(for: payload))
    }

    private static func region(for payload: LocationPayload) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng)
    }

    private var isLive: Bool { !payload.stop && !payload.isExpired }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                Marker(isLive ? "Live location" : "Shared location", coordinate: coordinate)
                    .tint(.red)
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .simultaneousGesture(DragGesture().onChanged { _ in following = false })
            .onChange(of: payload.lat) { _, _ in follow() }
            .onChange(of: payload.lng) { _, _ in follow() }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(isLive ? "Live Location" : "Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        following = true
                        withAnimation { position = Self.region(for: payload) }
                    } label: {
                        Label("Center", systemImage: following ? "location.fill" : "location")
                    }
                    Spacer()
                    Button {
                        let item = MKMapItem(location: CLLocation(latitude: payload.lat, longitude: payload.lng), address: nil)
                        item.name = isLive ? "Live location" : "Shared location"
                        item.openInMaps()
                    } label: {
                        Label("Open in Maps", systemImage: "map")
                    }
                }
            }
        }
    }

    private func follow() {
        guard following else { return }
        withAnimation(.easeInOut(duration: 0.5)) { position = Self.region(for: payload) }
    }
}

// MARK: - Notepad update bubble

struct NotepadUpdateBubble: View {
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.subheadline)
            Text("Notepad updated")
                .font(.subheadline)
        }
        .foregroundStyle(isOutgoing ? .white.opacity(0.9) : .secondary)
        .padding(.vertical, 4)
    }
}

// MARK: - Summary sheet

struct SummarySheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "No summary available." : text)
                    .font(.body)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("AI Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Schedule picker

struct SchedulePickerSheet: View {
    let draft: String
    @Binding var scheduledDate: Date
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Send at",
                    selection: $scheduledDate,
                    in: Date().addingTimeInterval(60)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                Section {
                    Text(draft)
                        .foregroundStyle(.secondary)
                        .font(.body)
                } header: {
                    Text("Message")
                } footer: {
                    Text("Relay sends it at this time if your phone is online. If Relay hasn't been able to run, it goes out the next time you open the app.")
                }
            }
            .navigationTitle("Schedule Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(scheduledDate)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Location share sheet

struct LocationShareSheet: View {
    @Binding var duration: TimeInterval
    let onStart: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss

    private let options: [(label: String, seconds: TimeInterval)] = [
        ("15 minutes", 900),
        ("1 hour", 3600),
        ("8 hours", 28800)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Share for") {
                    ForEach(options, id: \.seconds) { opt in
                        Button {
                            duration = opt.seconds
                        } label: {
                            HStack {
                                Text(opt.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if duration == opt.seconds {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Your live location is shared end-to-end encrypted. Only the people in this conversation can see it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Share Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onStart(duration)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - View-once overlay

struct ViewOnceOverlay: View {
    let message: StoredMessage
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool

    @State private var viewed = false
    @State private var image: UIImage?
    @State private var unavailable = false
    @State private var sensitiveHidden = false

    private var tint: Color { isOutgoing ? .white : .primary }
    /// The attachment row is deleted once the recipient has opened it.
    private var alreadyOpened: Bool { !isOutgoing && message.attachments.isEmpty }

    var body: some View {
        Group {
            if viewed, let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: sensitiveHidden ? 40 : 0)
                    .frame(maxWidth: 240)
                    .overlay {
                        if sensitiveHidden {
                            SensitiveMediaCover(restricted: SensitiveContent.isRestricted) {
                                sensitiveHidden = false
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 12))
            } else if isOutgoing || alreadyOpened || unavailable {
                // The sender can't open their own view-once photo (it would
                // destroy their copy); a recipient gets one look.
                label(
                    icon: alreadyOpened || unavailable ? "eye.slash" : "eye",
                    text: isOutgoing ? "View-once photo" : (unavailable ? "Photo unavailable" : "Opened")
                )
                .opacity(0.8)
            } else {
                Button { Task { await reveal() } } label: {
                    label(icon: "eye.fill", text: "View once")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the photo one time")
            }
        }
        .padding(8)
    }

    private func label(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.15), in: .capsule)
    }

    private func reveal() async {
        guard let attachment = message.attachments.first(where: { $0.isImage }) else { return }
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let data = service.attachmentPlaintext(attachment),
              let ui = SafeImage.image(from: data) else {
            unavailable = true
            return
        }
        sensitiveHidden = await SensitiveContent.isSensitive(image: ui, cacheKey: attachment.id)
        image = ui
        viewed = true
        // Delete the ciphertext and attachment row right after display so it
        // can't be shown or re-downloaded again.
        // Every attachment goes, not just the one shown: a modified sender
        // could otherwise attach more that stay viewable.
        let all = message.attachments
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for attachment in all { service.deleteViewOnceAttachment(attachment, in: conversationId) }
        }
    }
}

// MARK: - In-app browser

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
