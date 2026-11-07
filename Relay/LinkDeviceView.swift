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
        Form {
            Section {
                SettingsHero(systemName: "qrcode.viewfinder", color: .orange, title: "Link a New Device",
                             message: "On your new device, choose “Link existing device” to show its code, then scan it here.")
                    .settingsBareRow()
            }
            if service.chatListKeyForLinking != nil {
                Section {
                    Label("Your chats and message history come across from your encrypted backup.",
                          systemImage: "lock.icloud.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                legacySyncOptions
            }
            Section {
                SettingsPrimaryButton(title: "Scan Device Code", systemName: "qrcode.viewfinder", color: .orange) {
                    phase = .scanning
                }
                .settingsBareRow()
            }
        }
    }

    /// Accounts without an encrypted chat list copy a little history across instead.
    private var legacySyncOptions: some View {
        Section {
            Toggle(isOn: $syncConversations) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync conversation list")
                    Text("The new device will see your existing chats.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $syncHistory) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync message history")
                    Text("Transfers up to 50 recent messages per chat, end-to-end encrypted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!syncConversations)
            .onChange(of: syncConversations) { _, on in if !on { syncHistory = false } }
        }
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

    /// "iPad", "Mac" or "iPhone" from the name the new device reported.
    private var pendingDeviceKind: String {
        let name = pendingDeviceName.lowercased()
        if name.contains("ipad") { return "iPad" }
        if name.contains("mac") { return "Mac" }
        if name.contains("iphone") { return "iPhone" }
        return "Device"
    }

    private var confirmView: some View {
        Form {
            Section {
                SettingsHero(systemName: pendingDeviceKind == "iPad" ? "ipad" : pendingDeviceKind == "Mac" ? "laptopcomputer" : "iphone",
                             color: .orange, title: "Link This \(pendingDeviceKind)?",
                             message: "Only continue if it's your own \(pendingDeviceKind.lowercased()) and it's in front of you. Someone who gets you to scan their code gets your account.")
                    .settingsBareRow()
            }
            Section {
                LabeledContent("Device", value: pendingDeviceName)
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "key.fill", color: .yellow)
                    Text("Sends and receives messages as you")
                }
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "bubble.left.and.bubble.right.fill", color: .green)
                    Text(service.chatListKeyForLinking != nil
                         ? "Gets your chats and history from your backup"
                         : syncHistory ? "Gets your chats and recent messages"
                         : syncConversations ? "Gets your chat list" : "Starts with no chats")
                }
            } footer: {
                Text("You can remove it any time in Linked Devices.")
            }
            Section {
                SettingsPrimaryButton(title: "Link \(pendingDeviceKind)", systemName: "checkmark", color: .orange) {
                    confirmLink()
                }
                .settingsBareRow()
                Button("Cancel") {
                    pendingLink = nil
                    phase = .options
                }
                .tint(.primary)
                .frame(maxWidth: .infinity)
                .settingsBareRow()
            }
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

    private var deviceKind: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: "iPad"
        case .mac: "Mac"
        default: "device"
        }
    }

    var body: some View {
        ZStack {
            BackgroundGradient()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 20) {
                        HStack {
                            Button {
                                linkTask?.cancel()
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(.ultraThinMaterial, in: .circle)
                            }
                            .accessibilityLabel("Cancel")
                            Spacer()
                        }
                        .padding(.top, 16)

                        if let confirmation = model.linkConfirmation {
                            // Someone who photographed the code could answer it
                            // with their own account: check it's yours first.
                            AvatarView(name: confirmation.username, size: 96)
                                .padding(.top, 40)
                            OnboardingHeader(title: "@\(confirmation.username)",
                                             subtitle: "Is this your account? Only continue if it's the username you just linked from.")
                            OnboardingPrimaryButton(title: "Continue") {
                                qrImage = nil
                                status = "Setting up…"
                                confirmation.respond(true)
                            }
                                .frame(maxWidth: 460)
                            Button("This Isn't Me") { confirmation.respond(false) }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(minHeight: 44)
                        } else if let qrImage {
                            OnboardingHeader(title: "Link to Your Account",
                                             subtitle: "Scan this code with Relay on your phone to use your account on this \(deviceKind).")
                            // As big as the screen allows: a phone camera reads a
                            // large code quickly from a comfortable distance.
                            let side = max(200, min(geo.size.width - 48, geo.size.height * 0.5, 460))
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(side * 0.06)
                                .frame(width: side, height: side)
                                .background(.white, in: .rect(cornerRadius: 24, style: .continuous))
                                .accessibilityLabel("Device link code")
                            HStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text(status).font(.footnote).foregroundStyle(.white.opacity(0.7))
                            }
                            VStack(spacing: 0) {
                                step("iphone", "Open Relay on your phone")
                                Divider().background(.white.opacity(0.12)).padding(.leading, 52)
                                step("person.crop.circle", "Go to Profile → Account → Linked Devices")
                                Divider().background(.white.opacity(0.12)).padding(.leading, 52)
                                step("qrcode.viewfinder", "Tap Link a New Device and scan this code")
                            }
                            .onboardingCard()
                            .frame(maxWidth: 460)
                        } else if let errorMessage {
                            OnboardingHeader(title: "Linking Failed", subtitle: errorMessage)
                            OnboardingPrimaryButton(title: "Try Again") { start() }
                                .frame(maxWidth: 460)
                        } else {
                            ProgressView(status)
                                .tint(.white)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.top, 120)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard !started else { return }
            started = true
            start()
        }
        // Stop polling once the user leaves, or a late approval could still flip the
        // app into the account.
        .onDisappear { linkTask?.cancel() }
    }

    private func step(_ icon: String, _ text: String) -> some View {
        OnboardingRow(icon: icon) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        // Whole pixels per module, so the code stays sharp at any size.
        let scale: CGFloat = 16
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
    @State private var regionsShown = false
    @State private var relinkNudgeDismissed = UserDefaults.standard.bool(forKey: Self.relinkNudgeDismissedKey)

    private static let relinkNudgeDismissedKey = "relay.relinkNudgeDismissed"

    /// A secondary linked without the shared identity has a self-generated one,
    /// so its safety numbers differ from the account's. Nudge the user once to
    /// re-link it; provisioned devices set `identityProvisionedKey` and skip this.
    private var showRelinkNudge: Bool {
        // Only with another device whose numbers could differ: a phone that
        // signed in again (a new device id) has nothing to match.
        !relinkNudgeDismissed
            && devices.count > 1
            && service.credentials.deviceId != 1
            && !UserDefaults.standard.bool(forKey: AppModel.identityProvisionedKey)
    }

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "laptopcomputer.and.iphone", color: .orange,
                             message: "Use Relay on your iPad, Mac or another iPhone. Each device gets your chats and keeps them end-to-end encrypted.")
                    .settingsBareRow()
            }
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                if showRelinkNudge {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                SettingsIcon(systemName: "checkmark.shield.fill", color: .green)
                                Text("Re-link for verifiable safety numbers")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text("This device was linked before Relay shared one identity per account. Unlink and link it again so its safety numbers match your other devices.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Got it") {
                                relinkNudgeDismissed = true
                                UserDefaults.standard.set(true, forKey: Self.relinkNudgeDismissedKey)
                            }
                            .tint(.primary)
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    ForEach(devices) { device in
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: deviceIcon(device),
                                         color: device.deviceId == service.credentials.deviceId ? .orange : .gray)
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
                    SettingsPrimaryButton(title: "Link a New Device", systemName: "plus", color: .orange) {
                        showingLinkSheet = true
                    }
                    .settingsBareRow()
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { regionsShown },
                        set: { on in
                            regionsShown = on
                            Task {
                                if !(await service.setShowsDeviceRegions(on)) { regionsShown = !on }
                                await refresh()
                            }
                        }
                    )) {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "location.fill", color: .blue)
                            Text("Show Device Regions")
                        }
                    }
                } footer: {
                    Text("Adds an approximate region like \"Queensland, Australia\" to each device's name here. Applies to all your devices; each asks for approximate location once. The region is worked out by Apple and never reaches Relay's servers.")
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
        .task {
            regionsShown = service.regionSetting.on
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceRegionAuthorizationChanged)) { _ in
            // MessagingService republishes this device's label; show it.
            Task {
                try? await Task.sleep(for: .seconds(2))
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
        guard let device = Self.camera(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        Self.setUpFocus(device)

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

    /// The multi-lens camera where there is one: like the Camera app it
    /// switches to the ultra wide lens up close, so a code on a nearby
    /// screen comes into focus.
    private static func camera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
    }

    private static func setUpFocus(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isVirtualDevice {
            // Start on the wide lens (1x), not the ultra wide the virtual
            // device reports as 1.0; it drops back down on its own up close.
            if let wide = device.virtualDeviceSwitchOverVideoZoomFactors.first {
                device.videoZoomFactor = CGFloat(truncating: wide)
            }
        } else if device.minimumFocusDistance > 0 {
            // A single lens: zoom in so a code filling the frame is held
            // beyond the closest distance the lens can focus at.
            let halfFOV = Double(device.activeFormat.videoFieldOfView) / 2 * .pi / 180
            let closestForCode = 50 / tan(halfFOV)  // mm, a 5 cm code across the frame
            let minimum = Double(device.minimumFocusDistance)
            if closestForCode < minimum {
                device.videoZoomFactor = min(CGFloat(minimum / closestForCode), device.activeFormat.videoMaxZoomFactor)
            }
        }
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
