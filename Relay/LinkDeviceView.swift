//
//  LinkDeviceView.swift
//  Relay
//
//  Reversed (Signal-style) linking flow, so every device of an account shares
//  one identity key:
//  New device: shows a QR carrying its ephemeral key (via LinkNewDeviceView,
//    surfaced from OnboardingView) and polls for the encrypted payload.
//  Primary device: scans that QR (LinkDeviceView below), creates the device,
//    and seals the shared identity + credentials to the new device's key.
//
//  Manage linked devices (list + revoke) lives in LinkedDevicesView,
//  surfaced from SettingsView.
//

import AVFoundation
import CoreImage.CIFilterBuiltins
import RelayKit
import SecureStorage
import SwiftUI

// MARK: - Link Device (primary side — scan the new device's QR)

struct LinkDeviceView: View {
    let service: MessagingService

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case options          // choose sync toggles, then start scanning
        case scanning
        case provisioning
        case done
        case failed(String)
    }

    @State private var phase: Phase = .options
    @State private var syncConversations = true
    @State private var syncHistory = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .options:
                    optionsView
                case .scanning:
                    scannerView
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
                    phase = .failed(error.localizedDescription)
                }
            }
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
}

// MARK: - New device (show QR + poll for provisioning)

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
            // Stop polling the relay for the link payload once the user leaves —
            // otherwise a late approval could still flip the app into the account.
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
                // On success the model flips phase to .ready and onboarding dismisses.
            } catch is CancellationError {
                // The user cancelled; nothing to show.
            } catch {
                guard !Task.isCancelled else { return }
                // Drop the QR so the error state (and Try Again) is visible.
                qrImage = nil
                errorMessage = error.localizedDescription
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

// MARK: - Linked Devices management (settings)

struct LinkedDevicesView: View {
    let service: MessagingService

    @State private var devices: [RelayKit.LinkedDevice] = []
    @State private var loading = true
    @State private var showingLinkSheet = false
    @State private var errorMessage: String?
    @State private var pendingUnlink: RelayKit.LinkedDevice?
    @State private var relinkNudgeDismissed = UserDefaults.standard.bool(forKey: Self.relinkNudgeDismissedKey)

    private static let relinkNudgeDismissedKey = "relay.relinkNudgeDismissed"

    /// A secondary device linked before the shared-identity change still holds a
    /// self-generated identity, so its safety numbers differ from the account's.
    /// Nudge the user (once) to re-link it. New provisioned devices set
    /// `identityProvisionedKey`, so they never see this.
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
                            if device.deviceId == 1 {
                                Text("Primary")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { indexSet in
                        // Ask first — unlinking signs that device out for good.
                        pendingUnlink = indexSet.map { devices[$0] }.first { $0.deviceId != 1 }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("Swipe left to unlink a device. The primary device cannot be removed.")
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
        .navigationTitle("Linked Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .task { await refresh() }
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
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        loading = true
        do {
            devices = try await service.listLinkedDevices()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func deviceIcon(_ d: RelayKit.LinkedDevice) -> String {
        let name = d.name?.lowercased() ?? ""
        if name.contains("ipad") { return "ipad" }
        if name.contains("mac") { return "laptopcomputer" }
        return "iphone"
    }

    private func deviceTitle(_ d: RelayKit.LinkedDevice) -> String {
        let base = (d.name?.isEmpty == false ? d.name! : "Device \(d.deviceId)")
        return d.deviceId == service.credentials.deviceId ? "\(base) (this device)" : base
    }

    private func deviceSubtitle(_ d: RelayKit.LinkedDevice) -> String? {
        guard let ms = d.createdAt, ms > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return "Linked \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - QR Scanner (AVCapture, inline)

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
