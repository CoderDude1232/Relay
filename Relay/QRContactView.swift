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
    /// Optional generator for a one-time, single-use contact invite link.
    var createInviteLink: (() async throws -> URL)? = nil

    @Environment(\.dismiss) private var dismiss
    // Fixed card style — the colour picker was removed to keep this view uncluttered.
    private let preset = QRPreset.all[0]
    @State private var qrImage: UIImage?
    @State private var shareCard: UIImage?
    @State private var showingShare = false
    @State private var inviteLink: URL?
    @State private var showingInviteShare = false
    @State private var generatingInvite = false
    @State private var inviteError: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // The shareable card, near the top of the screen.
                cardView
                    .frame(maxWidth: 340)
                    .padding(.top, 24)

                // Controls pinned to the bottom. The one-time-link button is
                // hosted in a secure canvas so it is omitted from screenshots —
                // a screenshot captures only the card.
                VStack(spacing: 14) {
                    Spacer()

                    Text("relaymsg.app/add/\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    actionButtons
                        .hiddenInScreenshots()
                }
                .padding(.bottom, 10)
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
            .task {
                await regenerate()
            }
            .sheet(isPresented: $showingInviteShare) {
                if let inviteLink {
                    ActivitySheet(items: [inviteLink])
                        .presentationDetents([.medium])
                }
            }
            .alert("Invite Link", isPresented: Binding(
                get: { inviteError != nil },
                set: { if !$0 { inviteError = nil } }
            )) {
                Button("OK") { inviteError = nil }
            } message: {
                Text(inviteError ?? "")
            }
        }
    }

    // The gradient card (QR + username) — the only thing meant to survive a
    // screenshot.
    private var cardView: some View {
        VStack(spacing: 18) {
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
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .accessibilityLabel("Generating QR code")
                }
            }
            .padding(18)
            .background(.white, in: .rect(cornerRadius: 16, style: .continuous))

            Text("@\(username)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 2)
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [preset.topColor, preset.botColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: .rect(cornerRadius: 32, style: .continuous)
        )
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if let createInviteLink {
                Button {
                    generatingInvite = true
                    Task {
                        defer { generatingInvite = false }
                        do {
                            inviteLink = try await createInviteLink()
                            showingInviteShare = true
                        } catch {
                            inviteError = "Could not create a one-time link. Try again."
                        }
                    }
                } label: {
                    if generatingInvite {
                        ProgressView()
                    } else {
                        Label("Create One-Time Invite Link", systemImage: "link.badge.plus")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(generatingInvite)
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

// MARK: - Screenshot-hidden container

extension View {
    /// Hosts the view inside a UITextField's secure-entry canvas: it renders
    /// normally on screen and stays interactive, but iOS omits that layer from
    /// screenshots and screen recordings. Used to keep editing chrome out of a
    /// shared screenshot of the QR card.
    @ViewBuilder
    func hiddenInScreenshots(_ active: Bool = true) -> some View {
        if active {
            // Reparents content into a secure UITextField canvas (omitted from
            // screenshots). Only apply when actually protecting — otherwise the
            // reparenting itself clips/letterboxes the content.
            ScreenshotHiddenContainer(active: true) { self }
        } else {
            self
        }
    }
}

private struct ScreenshotHiddenContainer<Content: View>: UIViewRepresentable {
    var active: Bool
    var content: Content

    init(active: Bool = true, @ViewBuilder content: () -> Content) {
        self.active = active
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(rootView: content) }

    func makeUIView(context: Context) -> UIView {
        let coord = context.coordinator
        let field = coord.secureField
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = true

        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        let host = coord.hosting.view!
        host.backgroundColor = .clear
        host.translatesAutoresizingMaskIntoConstraints = false

        // The secure canvas is the text field's first subview; reparent it into
        // our wrapper and host the SwiftUI content inside it. If the private view
        // isn't available, fall back to showing the content normally.
        let container: UIView = field.subviews.first ?? wrapper
        if container !== wrapper {
            container.subviews.forEach { $0.removeFromSuperview() }
            container.isUserInteractionEnabled = true
            container.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                container.topAnchor.constraint(equalTo: wrapper.topAnchor),
                container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ])
        }
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return wrapper
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hosting.rootView = content
        // Toggle screenshot omission live. The field is always created secure so
        // the secure canvas subview exists to host content; this just controls
        // whether that layer is captured by screenshots/recordings.
        context.coordinator.secureField.isSecureTextEntry = active
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        return context.coordinator.hosting.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
    }

    final class Coordinator {
        let secureField = UITextField()
        let hosting: UIHostingController<Content>
        init(rootView: Content) {
            hosting = UIHostingController(rootView: rootView)
            hosting.view.backgroundColor = .clear
        }
    }
}

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
