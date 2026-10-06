//
//  VerificationView.swift
//  Relay
//
//  Safety-number verification for a 1:1 conversation: shows the 60-digit
//  numeric fingerprint and a QR code of the scannable encoding, lets the
//  user compare in person (by digits or by scanning the peer's QR), and
//  marks the peer verified. A distinct state warns when a previously
//  verified contact's identity key has changed.
//
//  The QR carries the Base64 of libsignal's scannable fingerprint encoding
//  (ASCII, so it round-trips through AVFoundation's string decoding). Both
//  ends of a Relay conversation use this convention; there is no external
//  spec to match.
//

import AVFoundation
import CoreImage.CIFilterBuiltins
import CryptoCore
import Photos
import SecureStorage
import SwiftUI

struct VerificationView: View {
    let service: MessagingService
    let conversationId: String
    let peerName: String

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
            VStack(spacing: 24) {
                statusHeader(verification.state)

                if verification.state == .changed {
                    Label(
                        "\(peerName)’s safety number has changed. This can happen if they reinstalled Relay — or it could mean someone is intercepting your messages. Compare the number below before trusting it.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                }

                SafetyNumberGrid(numeric: verification.safetyNumber.numeric)

                if let qr = Self.qrImage(for: verification.safetyNumber.scannable) {
                    VStack(spacing: 8) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(12)
                            .background(.white, in: .rect(cornerRadius: 16))
                        Button {
                            saveQRToPhotos(qr)
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text("Compare these numbers with \(peerName) in person or over a call you trust — or tap Scan to check their code automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                actionButtons(verification.state)
            }
            .padding()
        }
    }

    private func statusHeader(_ state: VerificationState) -> some View {
        VStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 44))
                .foregroundStyle(state.tint)
            Text(state.label)
                .font(.headline)
                .foregroundStyle(state.tint)
        }
    }

    @ViewBuilder
    private func actionButtons(_ state: VerificationState) -> some View {
        VStack(spacing: 12) {
            Button {
                showingScanner = true
            } label: {
                Label("Scan \(peerName)’s Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .glassProminentCompat()

            if state == .verified {
                Button(role: .destructive) {
                    service.setVerified(false, conversationId: conversationId)
                    reload()
                } label: {
                    Text("Clear Verification").frame(maxWidth: .infinity)
                }
                .glassStyleCompat()
            } else {
                Button {
                    service.setVerified(true, conversationId: conversationId)
                    reload()
                } label: {
                    Text("Mark as Verified").frame(maxWidth: .infinity)
                }
                .glassStyleCompat()
            }
        }
        .controlSize(.large)
    }

    // MARK: - Actions

    private func reload() {
        verification = service.peerVerification(for: conversationId)
    }

    /// Saves with add-only Photos access. Uses the async authorization API so
    /// no callback runs off the main actor (the app target is MainActor by
    /// default, and a main-isolated closure invoked on Photos' background
    /// queue would trap). Denied/restricted access shows an alert with a
    /// shortcut to Settings instead of failing silently.
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
        let matched = service.verifyScanned(encoding, conversationId: conversationId)
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
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
        .textSelection(.enabled)
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
            break // denied/restricted — Settings has the toggle
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
