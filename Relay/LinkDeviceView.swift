//
//  LinkDeviceView.swift
//  Relay
//
//  Reversed (Signal-style) linking, so every device of an account shares one
//  identity key. The new device shows a QR carrying its ephemeral key
//  (LinkNewDeviceView) and polls for the encrypted payload; the primary scans
//  it (LinkDeviceView), creates the device, and seals the shared identity and
//  credentials to that key. LinkedDevicesView lists and revokes devices.
//

import AVFoundation
import CoreImage.CIFilterBuiltins
import RelayKit
import SecureStorage
import SwiftUI

// MARK: - Link Device (primary)

struct LinkDeviceView: View {
    let service: MessagingService

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case options          // choose sync toggles, then start scanning
        case scanning
        case confirming       // scanned; waiting for the user to approve
        case provisioning
        case done
        case failed(String)
    }

    @State private var phase: Phase = .options
    @State private var syncConversations = true
    @State private var syncHistory = false
    /// The scanned code awaiting the user's explicit approval.
    @State private var pendingLink: LinkQRPayload?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .options:
                    optionsView
                case .scanning:
                    scannerView
                case .confirming:
                    confirmView
                case .provisioning:
                    ProgressView("Linking device…")
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    ContentUnavailableView {
                        Label("Device Linked", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Your new device now shares this account's identity and is ready to use.")
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Linking Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { phase = .options }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Link New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .done ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private var optionsView: some View {
        VStack(spacing: 24) {
            ContentUnavailableView(
                "Link a New Device",
                systemImage: "qrcode.viewfinder",
                description: Text("On your new device, choose “Link existing device” to show its code, then scan it here.")
            )

            if service.chatListKeyForLinking != nil {
                Label("Your chats and message history come across from your encrypted backup.",
                      systemImage: "lock.icloud.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                legacySyncOptions
            }

            Spacer()

            Button {
                phase = .scanning
            } label: {
                Label("Scan Device Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
    }

    /// Accounts without an encrypted chat list copy a little history across instead.
    private var legacySyncOptions: some View {
            VStack(spacing: 0) {
                Toggle(isOn: $syncConversations) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync conversation list").font(.subheadline)
                        Text("The new device will see your existing chats.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()

                Divider().padding(.leading)

                Toggle(isOn: $syncHistory) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync message history").font(.subheadline)
                        Text("Transfers up to 50 recent messages per chat, end-to-end encrypted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .disabled(!syncConversations)
                .onChange(of: syncConversations) { _, on in if !on { syncHistory = false } }
            }
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
            .padding(.horizontal)
        .padding(.top, 24)
    }

    private var scannerView: some View {
        LinkQRScannerView { raw in
            guard phase == .scanning else { return }
            guard
                let data = raw.data(using: .utf8),
                let qr = try? JSONDecoder().decode(LinkQRPayload.self, from: data)
            else {
                phase = .failed("That QR code isn't a Relay device link code.")
                return
            }
            // Never provision straight from a scan: show what is being linked
            // and what it will receive, and require an explicit confirmation.
            pendingLink = qr
            phase = .confirming
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Text("Point the camera at the code shown on your new device.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding()
                .background(.ultraThinMaterial, in: .capsule)
                .padding(.bottom, 40)
        }
    }

    /// The name the new device reported in its QR code ("iPhone", "iPad", …).
    /// Self-reported, so it is shown as a hint, never trusted.
    private var pendingDeviceName: String {
        let raw = (pendingLink?.deviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40))
        return cleaned.isEmpty ? "Unnamed device" : cleaned
    }

    private var confirmView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 46, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                    Text("Link “\(pendingDeviceName)”?")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Only continue if this is your own device and you are holding it right now. Someone who tricks you into scanning their code gets full access to your account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    Text("This device will receive").font(.headline)
                    Label("Your account identity — it can send and receive messages as you", systemImage: "key.fill")
                    if service.chatListKeyForLinking != nil {
                        Label("Your chats and message history, from your encrypted backup", systemImage: "bubble.left.and.bubble.right.fill")
                    } else if syncConversations {
                        Label("Your conversation list (up to 50 chats)", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    if service.chatListKeyForLinking == nil, syncHistory {
                        Label("Recent message history (up to 50 messages per chat)", systemImage: "clock.arrow.circlepath")
                    }
                    Text("Device name as reported by the new device: \(pendingDeviceName). You can remove it any time in Profile → Linked Devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let qr = pendingLink {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Link code").font(.caption.weight(.semibold))
                            Text(LinkCode.make(ephemeralPublicKey: qr.ephemeralPublicKey, accountId: service.credentials.accountId))
                                .font(.title2.monospacedDigit().weight(.bold))
                            Text("The new device will show this code and your username before it joins. If either is different, don't continue on it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))

                Button {
                    confirmLink()
                } label: {
                    Text("Link This Device").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Cancel", role: .cancel) {
                    pendingLink = nil
                    phase = .options
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    private func confirmLink() {
        guard let qr = pendingLink else { phase = .options; return }
        // Approving a new device must prove the owner is present: with no
        // device passcode there's nothing to authenticate against, so refuse.
        guard BiometricGate.isPasscodeSet else {
            phase = .failed(BiometricGate.passcodeRequiredMessage)
            return
        }
        pendingLink = nil
        phase = .provisioning
        Task {
            do {
                try await service.provisionScannedDevice(
                    sessionId: qr.sessionId,
                    ephemeralPublicKey: qr.ephemeralPublicKey,
                    newDeviceServerURL: qr.serverURL,
                    deviceName: qr.deviceName,
                    syncConversations: syncConversations,
                    syncHistory: syncHistory
                )
                phase = .done
            } catch {
                phase = .failed(FriendlyError.message(for: error))
            }
        }
    }
}

// MARK: - New device

/// Shown on a brand-new device from onboarding. Generates an ephemeral key,
/// displays a QR for the primary to scan, and waits for the encrypted payload.
struct LinkNewDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: UIImage?
    @State private var status: String = "Preparing…"
    @State private var errorMessage: String?
    @State private var started = false
    @State private var linkTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let qrImage {
                    Text("Scan with your other device")
                        .font(.headline)
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(12)
                        .background(.white, in: .rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("On your existing device: Profile → Linked Devices → Link a New Device, then scan this code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Linking Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { start() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView(status).padding(.top, 60)
                }
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Link to Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        linkTask?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                guard !started else { return }
                started = true
                start()
            }
            // Stop polling once the user leaves, or a late approval could still flip the
            // app into the account.
            .onDisappear { linkTask?.cancel() }
        }
    }

    private func start() {
        linkTask?.cancel()
        errorMessage = nil
        qrImage = nil
        status = "Preparing…"
        linkTask = Task {
            do {
                let (qr, sessionId, ephemeral) = try await model.beginDeviceLinking()
                try Task.checkCancellation()
                qrImage = makeQRImage(qr)
                status = "Waiting for your other device…"
                try await model.completeDeviceLinking(sessionId: sessionId, ephemeral: ephemeral)
                // On success the model moves to .ready and onboarding dismisses.
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                // Drop the QR so the error state (and Try Again) is visible.
                qrImage = nil
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }

    private func makeQRImage(_ text: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 240 / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Linked Devices

struct LinkedDevicesView: View {
    let service: MessagingService

    @State private var devices: [RelayKit.LinkedDevice] = []
    @State private var loading = true
    @State private var showingLinkSheet = false
    @State private var errorMessage: String?
    @State private var pendingUnlink: RelayKit.LinkedDevice?
    @State private var regionEnabled = DeviceRegion.shared.isEnabled
    @State private var relinkNudgeDismissed = UserDefaults.standard.bool(forKey: Self.relinkNudgeDismissedKey)

    private static let relinkNudgeDismissedKey = "relay.relinkNudgeDismissed"

    /// A secondary linked without the shared identity has a self-generated one,
    /// so its safety numbers differ from the account's. Nudge the user once to
    /// re-link it; provisioned devices set `identityProvisionedKey` and skip this.
    private var showRelinkNudge: Bool {
        !relinkNudgeDismissed
            && service.credentials.deviceId != 1
            && !UserDefaults.standard.bool(forKey: AppModel.identityProvisionedKey)
    }

    var body: some View {
        List {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                if showRelinkNudge {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Re-link for verifiable safety numbers", systemImage: "checkmark.shield")
                                .font(.subheadline.weight(.semibold))
                            Text("This device was linked before Relay shared one identity per account. Unlink and link it again so its safety numbers match your other devices.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Got it") {
                                relinkNudgeDismissed = true
                                UserDefaults.standard.set(true, forKey: Self.relinkNudgeDismissedKey)
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    ForEach(devices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: deviceIcon(device))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deviceTitle(device))
                                if let subtitle = deviceSubtitle(device) {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .deleteDisabled(device.deviceId == service.credentials.deviceId)
                    }
                    .onDelete { indexSet in
                        // Unlinking signs that device out for good, so ask first. This device
                        // leaves via Sign Out instead.
                        pendingUnlink = indexSet.map { devices[$0] }
                            .first { $0.deviceId != service.credentials.deviceId }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("Swipe left to unlink a device. Device names and regions are shared only between your own devices, end-to-end encrypted — Relay's servers never see them.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { regionEnabled },
                        set: { on in
                            regionEnabled = on
                            on ? DeviceRegion.shared.enable() : DeviceRegion.shared.disable()
                        }
                    )) {
                        Label("Show This Device's Region", systemImage: "location")
                    }
                } footer: {
                    Text("Adds an approximate region like \"Queensland, Australia\" to this device's name on your other devices. Uses approximate location only, turned into a region name by Apple; it never reaches Relay's servers.")
                }

                Section {
                    Button {
                        showingLinkSheet = true
                    } label: {
                        Label("Link a New Device", systemImage: "plus.circle")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Linked Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .deviceRegionAuthorizationChanged)) { _ in
            regionEnabled = DeviceRegion.shared.isEnabled
            Task {
                await service.publishDeviceLabel(force: true)
                await refresh()
            }
        }
        .sheet(isPresented: $showingLinkSheet, onDismiss: { Task { await refresh() } }) {
            LinkDeviceView(service: service)
        }
        .confirmationDialog(
            "Unlink this device?",
            isPresented: Binding(get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }),
            titleVisibility: .visible,
            presenting: pendingUnlink
        ) { device in
            Button("Unlink", role: .destructive) { unlink(device) }
        } message: { _ in
            Text("It will stop receiving messages and lose access to this account.")
        }
    }

    private func unlink(_ device: RelayKit.LinkedDevice) {
        Task {
            do {
                try await service.removeLinkedDevice(deviceId: device.deviceId)
                await refresh()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }

    private func refresh() async {
        loading = true
        do {
            devices = try await service.listLinkedDevices()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
        loading = false
    }

    /// The device's own end-to-end label (never from the relay).
    private func label(_ d: RelayKit.LinkedDevice) -> DeviceLabel? {
        d.deviceId == service.credentials.deviceId
            ? service.myDeviceLabel
            : service.deviceLabel(forDevice: d.deviceId)
    }

    private func deviceIcon(_ d: RelayKit.LinkedDevice) -> String {
        let model = label(d)?.model.lowercased() ?? ""
        if model.contains("ipad") { return "ipad" }
        if model.contains("mac") { return "laptopcomputer" }
        return "iphone"
    }

    private func deviceTitle(_ d: RelayKit.LinkedDevice) -> String {
        label(d)?.displayName ?? "Device \(d.deviceId)"
    }

    private func deviceSubtitle(_ d: RelayKit.LinkedDevice) -> String? {
        var parts: [String] = []
        if d.deviceId == service.credentials.deviceId { parts.append("This device") }
        if let ms = d.createdAt, ms > 0 {
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)
            parts.append("Added \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - QR Scanner

private struct LinkQRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> LinkScannerVC {
        let vc = LinkScannerVC()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uvc: LinkScannerVC, context: Context) {}
}

private final class LinkScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    nonisolated(unsafe) private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var scanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !scanned,
              let obj = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue else { return }
        scanned = true
        session.stopRunning()
        onScan?(value)
    }
}
