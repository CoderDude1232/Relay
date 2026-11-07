//
//  VerificationView.swift
//  Relay
//
//  Safety-number verification with one contact, opened from their 1:1 chat or
//  from a group whose member's safety number changed.
//
//  The QR carries Base64 of libsignal's scannable fingerprint encoding, so it
//  survives AVFoundation's string decoding.
//

import AVFoundation
import CoreImage.CIFilterBuiltins
import CryptoCore
import Photos
import SecureStorage
import SwiftUI

struct VerificationView: View {
    let service: MessagingService
    /// Nil when the conversation has no peer; shows the no-session state.
    let peer: String?
    let peerName: String

    init(service: MessagingService, conversationId: String, peerName: String) {
        self.init(service: service, peer: service.verificationPeer(for: conversationId), peerName: peerName)
    }

    init(service: MessagingService, peer: String?, peerName: String) {
        self.service = service
        self.peer = peer
        self.peerName = peerName
    }

    @Environment(\.dismiss) private var dismiss
    @State private var verification: MessagingService.PeerVerification?
    @State private var showingScanner = false
    @State private var scanResult: ScanResult?
    @State private var qrSaveStatus: QRSaveStatus?

    private enum QRSaveStatus: Identifiable {
        case saved, denied, failed
        var id: Self { self }
    }

    private enum ScanResult: Identifiable {
        case matched, mismatched
        var id: Int { self == .matched ? 0 : 1 }
    }

    var body: some View {
        Group {
            if let verification {
                content(for: verification)
            } else {
                ContentUnavailableView(
                    "No Secure Session Yet",
                    systemImage: "lock.slash",
                    description: Text("Send a message to \(peerName) first, then come back to verify your safety number.")
                )
            }
        }
        .navigationTitle("Verify Safety Number")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .task {
            guard let peer else { return }
            await service.refreshPeerIdentitiesIfConflicting(peer: peer)
            reload()
            // Checked against the key directory every visit, so "verified
            // automatically" doesn't depend on something else having checked.
            await service.refreshTransparency(peer: peer)
            reload()
        }
        .sheet(isPresented: $showingScanner) {
            ScannerSheet { scanned in
                showingScanner = false
                handleScanned(scanned)
            }
        }
        .alert(item: $scanResult) { result in
            switch result {
            case .matched:
                return Alert(
                    title: Text("Verified"),
                    message: Text("The scanned code matches. \(peerName) is now marked verified."),
                    dismissButton: .default(Text("OK"))
                )
            case .mismatched:
                return Alert(
                    title: Text("Codes Don’t Match"),
                    message: Text("This code does not match your safety number with \(peerName). Do not trust this conversation until the numbers match."),
                    primaryButton: .default(Text("Scan Again")) { showingScanner = true },
                    secondaryButton: .cancel(Text("OK"))
                )
            }
        }
        .alert(item: $qrSaveStatus) { status in
            switch status {
            case .saved:
                return Alert(title: Text("Saved"), message: Text("QR code saved to your photo library."), dismissButton: .default(Text("OK")))
            case .denied:
                return Alert(
                    title: Text("Photos Access Needed"),
                    message: Text("Allow Relay to add photos in Settings to save the QR code."),
                    primaryButton: .default(Text("Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .failed:
                return Alert(title: Text("Couldn't Save"), message: Text("The QR code couldn't be saved to your photo library. Please try again."), dismissButton: .default(Text("OK")))
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for verification: MessagingService.PeerVerification) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // The code and the number, together, like a card to hold up.
                VStack(spacing: 16) {
                    if let qr = Self.qrImage(for: verification.safetyNumber.scannable) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(.white, in: .rect(cornerRadius: 14))
                            .accessibilityLabel("Safety number QR code")
                            .accessibilityHint("\(peerName) can scan this code to verify you.")
                    }
                    SafetyNumberGrid(numeric: verification.safetyNumber.numeric)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))

                status(verification)

                actionButtons(verification)
            }
            .padding()
        }
        .toolbar {
            if let qr = Self.qrImage(for: verification.safetyNumber.scannable) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { saveQRToPhotos(qr) } label: {
                            Label("Save Code to Photos", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
    }

    /// One short line about where things stand.
    private func status(_ verification: MessagingService.PeerVerification) -> some View {
        let (symbol, tint, title, detail): (String, Color, String, String) = {
            if verification.transparency == .mismatch {
                return ("exclamationmark.shield.fill", .red, "Can't be verified",
                        "Someone may be intercepting your messages with \(peerName). Compare these numbers in person before trusting this chat.")
            }
            switch verification.state {
            case .changed:
                return ("exclamationmark.shield.fill", .orange, "Safety number changed",
                        "This usually means \(peerName) reinstalled Relay or got a new phone. Compare the numbers to be sure.")
            case .verified:
                return ("checkmark.shield.fill", .green, "Verified", "You verified your safety number with \(peerName).")
            case .unverified:
                if verification.isVerifiedAutomatically {
                    return ("checkmark.shield.fill", .green, "Verified", "Your safety number with \(peerName) was verified automatically.")
                }
                return ("shield", .secondary, "Not verified",
                        "To verify, compare these numbers with \(peerName) or scan their code.")
            }
        }()
        return VStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .labelStyle(StatusLabelStyle(tint: tint))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    private struct StatusLabelStyle: LabelStyle {
        let tint: Color
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.foregroundStyle(tint)
                configuration.title
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ verification: MessagingService.PeerVerification) -> some View {
        if verification.hasConflictingKeys {
            Text("\(peerName) has a device with a different key, so this number can't be verified. Ask them to check their linked devices and remove any they don't recognise.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .glassProminentCompat()

                if verification.state == .verified {
                    Button(role: .destructive) {
                        if let peer { service.setVerified(false, peer: peer) }
                        reload()
                    } label: {
                        Text("Clear Verification").frame(maxWidth: .infinity)
                    }
                    .glassStyleCompat()
                } else if !verification.isVerifiedAutomatically {
                    Button {
                        if let peer { service.setVerified(true, peer: peer) }
                        reload()
                    } label: {
                        Text("Mark as Verified").frame(maxWidth: .infinity)
                    }
                    .glassStyleCompat()
                }
            }
            .controlSize(.large)
        }
    }

    // MARK: - Actions

    private func reload() {
        verification = peer.flatMap { service.peerVerification(forPeer: $0) }
    }

    /// Uses the async authorization API: a MainActor-isolated callback invoked
    /// on Photos' background queue would trap.
    private func saveQRToPhotos(_ image: UIImage) {
        Task {
            var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined {
                status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }
            guard status == .authorized || status == .limited else {
                qrSaveStatus = .denied
                return
            }
            do {
                try await Self.addToPhotoLibrary(image)
                qrSaveStatus = .saved
            } catch {
                qrSaveStatus = .failed
            }
        }
    }

    /// Nonisolated so the change block isn't inferred @MainActor (Photos runs
    /// it on its own queue).
    nonisolated private static func addToPhotoLibrary(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    private func handleScanned(_ scanned: String) {
        guard let encoding = Data(base64Encoded: scanned) else {
            scanResult = .mismatched
            return
        }
        let matched = peer.map { service.verifyScanned(encoding, peer: $0) } ?? false
        scanResult = matched ? .matched : .mismatched
        reload()
    }

    // MARK: - QR rendering

    private static func qrImage(for scannable: Data) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(scannable.base64EncodedString().utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Safety-number grid

/// The 60 digits laid out as 12 groups of 5, three per row.
/// Lists the group members whose safety number changed. Sends to the group
/// fail until each is reviewed, so this says who is holding them up.
struct GroupSafetyNumbersView: View {
    let service: MessagingService
    let conversationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var members: [String] = []

    var body: some View {
        List {
            Section {
                ForEach(members, id: \.self) { member in
                    let name = service.displayName(forAccount: member)
                    NavigationLink(destination: VerificationView(service: service, peer: member, peerName: name)) {
                        HStack(spacing: 12) {
                            AvatarView(name: name, size: 32, imageData: service.peerAvatarData(forAccount: member))
                            Text(name)
                        }
                    }
                }
            } footer: {
                Text(members.isEmpty
                     ? "Every member’s safety number is up to date. Messages to this group can be sent again."
                     : "Messages to this group won’t send until you review each changed safety number. Compare it with the person in another way, then mark it as verified.")
            }
        }
        .navigationTitle("Safety Numbers Changed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        members = service.groupMembersWithChangedSafetyNumbers(conversationId)
    }
}

private struct SafetyNumberGrid: View {
    let numeric: String

    private var groups: [String] {
        let digits = numeric.filter(\.isNumber)
        return stride(from: 0, to: digits.count, by: 5).map { offset in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            let end = digits.index(start, offsetBy: 5, limitedBy: digits.endIndex) ?? digits.endIndex
            return String(digits[start..<end])
        }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    // Read digit by digit, not as "forty-one thousand…".
                    .accessibilityLabel(group.map(String.init).joined(separator: " "))
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Safety number")
    }
}

// MARK: - Verification state presentation

private extension VerificationState {
    var symbol: String {
        switch self {
        case .verified: "checkmark.shield.fill"
        case .changed: "exclamationmark.shield.fill"
        case .unverified: "shield"
        }
    }

    var label: String {
        switch self {
        case .verified: "Verified"
        case .changed: "Safety Number Changed"
        case .unverified: "Not Verified"
        }
    }

    var tint: Color {
        switch self {
        case .verified: .green
        case .changed: .orange
        case .unverified: .secondary
        }
    }
}

// MARK: - QR scanner

/// A full-screen camera scanner in its own sheet, with a Cancel affordance.
private struct ScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView(onScan: onScan)
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    Text("Point the camera at your contact’s safety-number code.")
                        .font(.footnote)
                        .padding()
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(.bottom, 40)
                }
                .navigationTitle("Scan Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    // nonisolated(unsafe): the session is only ever touched on `sessionQueue`
    // (start/stop) or during MainActor setup; access is serialized by hand.
    nonisolated(unsafe) private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.relayapp.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.configureSession() }
            }
        default:
            break // denied/restricted; Settings has the toggle
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        start()
    }

    private func start() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didScan else { return }
            self.didScan = true
            self.onScan?(value)
        }
    }
}
