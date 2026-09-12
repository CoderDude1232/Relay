//
//  QRContactView.swift
//  Relay
//
//  QR codes for contact exchange.
//  QR payload:  relay://add/<username>  (opens Relay directly)
//  Share link:  https://relaymsg.app/add/<username>
//  Scanning:    DataScannerViewController (VisionKit, iOS 16+)
//

import CoreImage.CIFilterBuiltins
import CoreNFC
import SwiftUI
import Vision
import VisionKit

// MARK: - Gradient presets

private struct QRPreset: Identifiable, Equatable, Sendable {
    let id: String
    // Card gradient (top-left → bottom-right)
    let tR, tG, tB: Double
    let bR, bG, bB: Double
    // QR module colour (dark variant of the hue, on white QR background)
    let mR, mG, mB: Double

    var topColor: Color { Color(red: tR, green: tG, blue: tB) }
    var botColor: Color { Color(red: bR, green: bG, blue: bB) }

    static let all: [QRPreset] = [
        QRPreset(id: "purple",   tR: 0.50, tG: 0.24, tB: 0.88, bR: 0.26, bG: 0.10, bB: 0.60, mR: 0.16, mG: 0.04, mB: 0.44),
        QRPreset(id: "midnight", tR: 0.16, tG: 0.20, tB: 0.50, bR: 0.05, bG: 0.07, bB: 0.24, mR: 0.04, mG: 0.05, mB: 0.20),
        QRPreset(id: "ocean",    tR: 0.10, tG: 0.48, tB: 0.72, bR: 0.03, bG: 0.20, bB: 0.46, mR: 0.02, mG: 0.14, mB: 0.36),
        QRPreset(id: "forest",   tR: 0.10, tG: 0.50, tB: 0.28, bR: 0.03, bG: 0.24, bB: 0.12, mR: 0.02, mG: 0.16, mB: 0.07),
        QRPreset(id: "ember",    tR: 0.88, tG: 0.32, tB: 0.14, bR: 0.52, bG: 0.12, bB: 0.04, mR: 0.40, mG: 0.06, mB: 0.02),
        QRPreset(id: "rose",     tR: 0.82, tG: 0.24, tB: 0.48, bR: 0.48, bG: 0.08, bB: 0.28, mR: 0.38, mG: 0.04, mB: 0.18),
    ]
}

// MARK: - My QR code view

struct MyQRCodeView: View {
    let username: String

    @Environment(\.dismiss) private var dismiss
    @State private var preset    = QRPreset.all[0]
    @State private var qrImage: UIImage?
    @State private var shareCard: UIImage?
    @State private var showingShare = false
    @State private var nfcAlert: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Gradient card — no shadow
                VStack(spacing: 16) {
                    // QR code on white rounded background
                    Group {
                        if let image = qrImage {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel("QR code for \(username)")
                        } else {
                            ProgressView()
                                .tint(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 200)
                                .accessibilityLabel("Generating QR code")
                        }
                    }
                    .padding(16)
                    .background(.white, in: .rect(cornerRadius: 14, style: .continuous))

                    // Username sits below the QR, inside the card
                    Text("@\(username)")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.bottom, 2)
                }
                .padding(20)
                .background(
                    LinearGradient(
                        colors: [preset.topColor, preset.botColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 28, style: .continuous)
                )
                .frame(maxWidth: 300)
                .animation(.easeInOut(duration: 0.2), value: preset.id)

                // Preset picker
                HStack(spacing: 10) {
                    ForEach(QRPreset.all) { p in
                        Button { preset = p } label: {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [p.topColor, p.botColor],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if p == preset {
                                        Circle().strokeBorder(.white, lineWidth: 2.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(p.id)
                    }
                }

                VStack(spacing: 10) {
                    Text("relaymsg.app/add/\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if NFCContactManager.isAvailable {
                        Button {
                            NFCContactManager.shared.startWriting(username: username) { success in
                                nfcAlert = success
                                    ? "Contact link written! Anyone can tap this tag to add you on Relay."
                                    : "Could not write to tag. Make sure it is writable and try again."
                            }
                        } label: {
                            Label("Write to NFC Tag", systemImage: "wave.3.right")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 32)
            .navigationTitle("My QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingShare = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(shareCard == nil)
                }
            }
            .sheet(isPresented: $showingShare) {
                if let card = shareCard,
                   let link = URL(string: "https://relaymsg.app/add/\(username)") {
                    ActivitySheet(items: [card, link])
                        .presentationDetents([.medium, .large])
                }
            }
            .task(id: preset.id) {
                await regenerate()
            }
            .alert("NFC Tag", isPresented: Binding(
                get: { nfcAlert != nil },
                set: { if !$0 { nfcAlert = nil } }
            )) {
                Button("OK") { nfcAlert = nil }
            } message: {
                Text(nfcAlert ?? "")
            }
        }
    }

    private func regenerate() async {
        let name = username
        let p    = preset
        qrImage  = nil
        let qr   = await Task.detached(priority: .userInitiated) {
            makeQRImage(username: name, size: 900, modR: p.mR, modG: p.mG, modB: p.mB)
        }.value
        qrImage  = qr
        shareCard = await Task.detached(priority: .userInitiated) {
            renderShareCard(username: name, qrImage: qr,
                            topR: p.tR, topG: p.tG, topB: p.tB,
                            botR: p.bR, botG: p.bG, botB: p.bB,
                            modR: p.mR, modG: p.mG, modB: p.mB)
        }.value
    }
}

// MARK: - QR generation

nonisolated private func makeQRImage(
    username: String, size: CGFloat,
    modR: Double, modG: Double, modB: Double
) -> UIImage? {
    let context = CIContext()
    let filter  = CIFilter.qrCodeGenerator()
    filter.message         = Data("https://relaymsg.app/add/\(username)".utf8)
    filter.correctionLevel = "M"

    guard let output = filter.outputImage else { return nil }

    let scale  = size / output.extent.width
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    // Colour the modules to match the card; background stays white so the
    // QR is scannable against both light and dark module colours.
    let colorFilter = CIFilter.falseColor()
    colorFilter.inputImage = scaled
    colorFilter.color0     = CIColor(red: modR, green: modG, blue: modB)  // modules
    colorFilter.color1     = CIColor(red: 1, green: 1, blue: 1)            // background

    guard let coloured = colorFilter.outputImage,
          let cgImage  = context.createCGImage(coloured, from: coloured.extent)
    else { return nil }

    return UIImage(cgImage: cgImage)
}

// MARK: - Share card rendering

// Produces a standalone card image suitable for sharing via the system sheet.
// Mirrors the in-app card: gradient background, white rounded QR area, name below.
nonisolated private func renderShareCard(
    username: String, qrImage: UIImage?,
    topR: Double, topG: Double, topB: Double,
    botR: Double, botG: Double, botB: Double,
    modR: Double, modG: Double, modB: Double
) -> UIImage? {
    let cardW: CGFloat   = 680
    let inset: CGFloat   = 40          // padding inside the card
    let qrBg: CGFloat    = 16          // white QR background padding
    let qrSize           = cardW - inset * 2 - qrBg * 2
    let qrBgSize         = qrSize + qrBg * 2
    let nameH: CGFloat   = 60
    let linkH: CGFloat   = 36
    let cardH            = inset + qrBgSize + 16 + nameH + 16 + linkH + inset

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: cardW, height: cardH))
    return renderer.image { ctx in
        let fullRect = CGRect(x: 0, y: 0, width: cardW, height: cardH)
        let cgCtx    = ctx.cgContext

        // Gradient background
        let colors = [
            UIColor(red: topR, green: topG, blue: topB, alpha: 1).cgColor,
            UIColor(red: botR, green: botG, blue: botB, alpha: 1).cgColor,
        ] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0.0, 1.0])!
        UIBezierPath(roundedRect: fullRect, cornerRadius: 56).addClip()
        cgCtx.drawLinearGradient(grad, start: .zero,
                                 end: CGPoint(x: cardW, y: cardH), options: [])

        // White rounded QR background
        let qrBgRect = CGRect(x: inset, y: inset, width: qrBgSize, height: qrBgSize)
        UIColor.white.setFill()
        UIBezierPath(roundedRect: qrBgRect, cornerRadius: 20).fill()

        // QR image inside white area
        let qrRect = qrBgRect.insetBy(dx: qrBg, dy: qrBg)
        qrImage?.draw(in: qrRect)

        // @username below the white area
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 38, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let nameStr  = "@\(username)" as NSString
        let nameSize = nameStr.size(withAttributes: nameAttrs)
        let nameY    = inset + qrBgSize + 16 + (nameH - nameSize.height) / 2
        nameStr.draw(at: CGPoint(x: (cardW - nameSize.width) / 2, y: nameY),
                     withAttributes: nameAttrs)

        // Link at the bottom
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .regular),
            .foregroundColor: UIColor.white.withAlphaComponent(0.55),
        ]
        let linkStr  = "relaymsg.app/add/\(username)" as NSString
        let linkSize = linkStr.size(withAttributes: linkAttrs)
        let linkY    = inset + qrBgSize + 16 + nameH + 16
        linkStr.draw(at: CGPoint(x: (cardW - linkSize.width) / 2, y: linkY),
                     withAttributes: linkAttrs)
    }
}

// MARK: - UIActivityViewController wrapper

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - QR scanner (wraps DataScannerViewController)

struct ContactQRScanner: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scanned = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DataScannerRepresentable(onScan: handleScan)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("This device does not support the QR scanner.")
                    )
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if NFCContactManager.isAvailable {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            NFCContactManager.shared.startReading { username in
                                handleScan(username)
                            }
                        } label: {
                            Label("Scan NFC Tag", systemImage: "wave.3.right")
                        }
                    }
                }
            }
        }
    }

    private func handleScan(_ username: String) {
        guard !scanned else { return }
        scanned = true
        dismiss()
        onScan(username)
    }
}

// MARK: - UIViewControllerRepresentable

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue
            else { return }
            let username = extractUsername(from: payload)
            guard !username.isEmpty else { return }
            onScan(username)
        }

        private func extractUsername(from payload: String) -> String {
            if let url = URL(string: payload) {
                // relay://add/<username>
                if url.scheme == "relay", url.host == "add",
                   let name = url.pathComponents.dropFirst().first { return name }
                // https://relaymsg.app/add/<username>
                if url.host == "relaymsg.app", url.pathComponents.count >= 3,
                   url.pathComponents[1] == "add" { return url.pathComponents[2] }
            }
            // legacy relay:<username>
            if payload.hasPrefix("relay:") { return String(payload.dropFirst("relay:".count)) }
            return ""
        }
    }
}
