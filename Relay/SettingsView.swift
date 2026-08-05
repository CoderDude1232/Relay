//
//  SettingsView.swift
//  Relay
//

import PhotosUI
import RelayKit
import SwiftUI
import UIKit

struct SettingsView: View {
    let service: MessagingService

    @Environment(AppModel.self) private var model
    @State private var confirmingSignOut = false
    @State private var editingServer = false
    @State private var serverDraft = ""
    @State private var serverError: String?
    @State private var profilePhoto: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var displayNameDraft = ""

    private var displayName: String {
        let name = service.myDisplayName ?? service.username
        return name?.isEmpty == false ? name! : "Unknown"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(name: displayName, size: 56, imageData: avatarData)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName)
                                .font(.title3.bold())
                            Text(connectionLabel)
                                .font(.footnote)
                                .foregroundStyle(connectionColor)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Profile") {
                    PhotosPicker(selection: $profilePhoto, matching: .images) {
                        HStack {
                            Text("Profile Photo")
                            Spacer()
                            AvatarView(name: displayName, size: 32, imageData: avatarData)
                        }
                    }
                    .tint(.primary)
                    if avatarData != nil {
                        Button("Remove Photo", role: .destructive) { setAvatar(nil) }
                    }
                    HStack {
                        Text("Display Name")
                        Spacer()
                        TextField("Your name", text: $displayNameDraft)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .onSubmit(saveDisplayName)
                    }
                    if let username = service.username {
                        LabeledContent("Username", value: "@\(username)")
                    }
                }

                Section("Account") {
                    LabeledContent("Account ID") {
                        Text(service.credentials.accountId)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Device", value: "#\(service.credentials.deviceId)")
                    Button {
                        serverDraft = service.serverURL.absoluteString
                        serverError = nil
                        editingServer = true
                    } label: {
                        LabeledContent("Server", value: service.serverURL.absoluteString)
                    }
                    .tint(.primary)
                    if let serverError {
                        Text(serverError).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("Chat Appearance", systemImage: "paintbrush")
                    }
                }

                Section("Security") {
                    LabeledContent("Encryption", value: "Signal protocol (PQXDH)")
                    LabeledContent("Local storage", value: "SQLCipher encrypted")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        confirmingSignOut = true
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                avatarData = service.myAvatarData
                displayNameDraft = service.myDisplayName ?? ""
            }
            .onChange(of: profilePhoto) { _, item in loadPhoto(item) }
            .onDisappear(perform: saveDisplayName)
            .confirmationDialog(
                "Sign out and delete all local messages?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out & Delete", role: .destructive) {
                    model.signOut()
                }
            } message: {
                Text("Message history only exists on this device — it cannot be recovered.")
            }
            .alert("Change Server", isPresented: $editingServer) {
                TextField("https://host:port", text: $serverDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Update") {
                    guard let url = URL(string: serverDraft.trimmingCharacters(in: .whitespaces)) else {
                        serverError = "That doesn't look like a valid URL."
                        return
                    }
                    serverError = model.updateServerURL(url)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Reconnects this account to a new relay URL without deleting your messages.")
            }
        }
    }

    private func saveDisplayName() {
        service.setMyDisplayName(displayNameDraft)
    }

    private func setAvatar(_ data: Data?) {
        avatarData = data
        service.setMyAvatarData(data)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let downscaled = image.avatarJPEG() else { return }
            setAvatar(downscaled)
        }
    }

    private var connectionLabel: String {
        switch service.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Offline"
        }
    }

    private var connectionColor: Color {
        switch service.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }
}

/// A circular avatar: a profile photo when supplied, otherwise a colored
/// initial derived from the name.
struct AvatarView: View {
    let name: String
    var size: CGFloat = 44
    var imageData: Data? = nil

    var body: some View {
        Group {
            if let imageData, let ui = UIImage(data: imageData) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(color.gradient)
                    .overlay {
                        Text(initial)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }
}

extension UIImage {
    /// Downscales and re-encodes an image to a small square-ish JPEG suitable
    /// for a profile avatar (keeps the stored/transmitted blob tiny).
    func avatarJPEG(maxDimension: CGFloat = 256, quality: CGFloat = 0.8) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
