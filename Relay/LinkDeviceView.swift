//
//  LinkDeviceView.swift
//  Relay
//
//  Two-sided linking flow:
//  Primary device: generates credentials + shows QR code
//  Linking device: scans QR → boots as the same account (via OnboardingView)
//
//  Manage linked devices (list + revoke) lives in LinkedDevicesView,
//  surfaced from SettingsView.
//

import AVFoundation
import CoreImage.CIFilterBuiltins
import RelayKit
import SecureStorage
import SwiftUI

// MARK: - Link Device (primary side — show QR)

struct LinkDeviceView: View {
    let service: MessagingService

    @Environment(\.dismiss) private var dismiss
    @State private var qrPayload: String?
    @State private var qrImage: UIImage?
    @State private var verificationCode: String?
    @State private var generating = false
    @State private var errorMessage: String?
    @State private var syncConversations = true
    @State private var syncHistory = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if generating {
                    ProgressView("Generating link code…")
                        .padding(.top, 60)
                } else if let qrImage {
                    VStack(spacing: 16) {
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

                        if let verificationCode {
                            Text(verificationCode)
                                .font(.title2.monospacedDigit().weight(.semibold))
                                .textSelection(.enabled)
                        }

                        Text("This code expires in 10 minutes or after it is used.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    ContentUnavailableView(
                        "Generate a Link Code",
                        systemImage: "qrcode",
                        description: Text("Tap Generate to create a one-time code for linking a new device.")
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                Spacer()

                VStack(spacing: 0) {
                    Toggle(isOn: $syncConversations) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync conversation list")
                                .font(.subheadline)
                            Text("Linked device will see your existing chats.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .disabled(qrImage != nil)

                    Divider()
                        .padding(.leading)

                    Toggle(isOn: $syncHistory) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync message history")
                                .font(.subheadline)
                            Text("Transfers up to 50 recent messages per chat, end-to-end encrypted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .disabled(qrImage != nil || !syncConversations)
                    .onChange(of: syncConversations) { _, on in
                        if !on { syncHistory = false }
                    }
                }
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                .padding(.horizontal)

                Button {
                    generate()
                } label: {
                    Label("Generate Link Code", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(generating)
            }
            .padding(.top, 24)
            .navigationTitle("Link New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func generate() {
        generating = true
        errorMessage = nil
        qrImage = nil
        verificationCode = nil
        Task {
            do {
                let payload = try await service.provisionLinkedDevice(syncConversations: syncConversations, syncHistory: syncHistory)
                let image = makeQRImage(payload)
                let verificationCode = Self.verificationCode(from: payload)
                await MainActor.run {
                    qrPayload = payload
                    qrImage = image
                    self.verificationCode = verificationCode
                    generating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to generate link code: \(error.localizedDescription)"
                    generating = false
                }
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

    private static func verificationCode(from payload: String) -> String? {
        guard
            let data = payload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["verificationCode"] as? String
    }
}

// MARK: - Scan Link Code (linking device side)

/// Scans a linking QR from the primary device and returns the decoded payload.
struct ScanLinkCodeView: View {
    let onScanned: (LinkPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            LinkQRScannerView { raw in
                guard
                    let data = raw.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let linkToken = json["linkToken"] as? String,
                    let verificationCode = json["verificationCode"] as? String,
                    let serverURLStr = json["serverURL"] as? String,
                    let serverURL = URL(string: serverURLStr)
                else {
                    errorMessage = "Invalid link code."
                    return
                }
                let peers: [(account: String, username: String?)] =
                    (json["peers"] as? [[String: String]] ?? []).compactMap { d in
                        guard let account = d["account"], !account.isEmpty else { return nil }
                        return (account: account, username: d["username"])
                    }
                let historyKey: Data? = (json["historyKey"] as? String).flatMap { Data(base64Encoded: $0) }
                let historyDigest: Data? = (json["historyDigest"] as? String).flatMap { Data(base64Encoded: $0) }
                let payload = LinkPayload(
                    linkToken: linkToken,
                    verificationCode: verificationCode,
                    serverURL: serverURL,
                    username: json["username"] as? String,
                    peers: peers,
                    historyAttachmentId: json["historyId"] as? String,
                    historyKey: historyKey,
                    historyDigest: historyDigest
                )
                onScanned(payload)
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                    Text("Point the camera at the link code shown on your primary device.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.ultraThinMaterial, in: .capsule)
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("Scan Link Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

public struct LinkPayload: Sendable {
    public let linkToken: String
    public let verificationCode: String
    public let serverURL: URL
    public let username: String?
    /// 1:1 conversation peers to pre-populate on the linked device (empty = no sync).
    public let peers: [(account: String, username: String?)]
    /// Relay blob id, AES key, and SHA-256 digest for the encrypted message history upload (nil = no history).
    public let historyAttachmentId: String?
    public let historyKey: Data?
    public let historyDigest: Data?

    public init(
        linkToken: String, verificationCode: String, serverURL: URL, username: String?,
        peers: [(account: String, username: String?)],
        historyAttachmentId: String? = nil, historyKey: Data? = nil, historyDigest: Data? = nil
    ) {
        self.linkToken = linkToken
        self.verificationCode = verificationCode
        self.serverURL = serverURL
        self.username = username
        self.peers = peers
        self.historyAttachmentId = historyAttachmentId
        self.historyKey = historyKey
        self.historyDigest = historyDigest
    }
}

// MARK: - Linked Devices management (settings)

struct LinkedDevicesView: View {
    let service: MessagingService

    @State private var devices: [RelayKit.LinkedDevice] = []
    @State private var loading = true
    @State private var showingLinkSheet = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(devices) { device in
                        HStack {
                            Image(systemName: device.deviceId == 1 ? "iphone.homebutton" : "iphone")
                                .foregroundStyle(.secondary)
                            Text(device.deviceId == 1 ? "This device (primary)" : "Device \(device.deviceId)")
                            Spacer()
                            if device.deviceId == 1 {
                                Text("Primary")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let d = devices[index]
                            guard d.deviceId != 1 else { continue }
                            Task {
                                do {
                                    try await service.removeLinkedDevice(deviceId: d.deviceId)
                                    await refresh()
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
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
