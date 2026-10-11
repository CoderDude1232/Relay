//
//  QRContactView.swift
//  Relay
//
//  QR codes for contact exchange. The code encodes
//  https://relaymsg.app/add/<username>; scanning uses DataScannerViewController.
//

import CoreImage.CIFilterBuiltins
import SwiftUI
import AVFoundation
import Vision
import VisionKit

// MARK: - Gradient presets

private struct QRPreset: Identifiable, Equatable, Sendable {
    let id: String
    // Card gradient, top-left to bottom-right.
    let tR, tG, tB: Double
    let bR, bG, bB: Double
    // QR module colour: a dark variant of the hue, on a white background.
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
    var displayName: String? = nil
    var avatarData: Data? = nil
    /// Optional generator for a one-time, single-use contact invite link.
    var createInviteLink: (() async throws -> URL)? = nil

    @Environment(\.dismiss) private var dismiss
    /// "photo", a preset id, or empty for the default (photo if there is one).
    @AppStorage("qr.preset") private var presetId = ""
    @State private var photoColor: (r: Double, g: Double, b: Double)?
    @State private var qrImage: UIImage?
    @State private var shareCard: UIImage?
    @State private var showingShare = false
    @State private var linkCopied = false
    @State private var inviteLink: URL?
    @State private var showingInviteShare = false
    @State private var generatingInvite = false
    @State private var inviteError: String?

    private var photo: UIImage? { avatarData.flatMap { DecodedImageCache.image(for: $0) } }
    private var usesPhoto: Bool { photo != nil && (presetId == "photo" || presetId.isEmpty) }
    private var selectedId: String { usesPhoto ? "photo" : preset.id }
    private var preset: QRPreset { QRPreset.all.first { $0.id == presetId } ?? QRPreset.all[0] }
    /// QR module colour: a dark shade of the photo when it's the background.
    private var moduleColor: (r: Double, g: Double, b: Double) {
        usesPhoto ? (photoColor ?? (preset.mR, preset.mG, preset.mB)) : (preset.mR, preset.mG, preset.mB)
    }
    private var link: String { "https://relaymsg.app/add/\(username)" }
    private var name: String { (displayName?.isEmpty == false ? displayName : nil) ?? "@\(username)" }

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.3), value: selectedId)

                ScrollView {
                    VStack(spacing: 26) {
                        cardView
                            .padding(.top, 48)
                        // Controls are hidden from screenshots so only the card is captured.
                        controls
                            .hiddenInScreenshots()
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("My QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShare) {
                if let card = shareCard, let url = URL(string: link) {
                    ActivitySheet(items: [card, url])
                        .presentationDetents([.medium, .large])
                }
            }
            .sheet(isPresented: $showingInviteShare) {
                if let inviteLink {
                    ActivitySheet(items: [inviteLink])
                        .presentationDetents([.medium])
                }
            }
            .task(id: selectedId) { await regenerate() }
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

    /// The profile photo blurred like the call screens, or the chosen gradient.
    @ViewBuilder
    private var backdrop: some View {
        if usesPhoto, let photo {
            ZStack {
                Color.black
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80, opaque: true)
                    .saturation(2.2)
                    .brightness(-0.05)
                    .overlay(Color.black.opacity(0.38))
            }
        } else {
            LinearGradient(colors: [preset.topColor, preset.botColor], startPoint: .top, endPoint: .bottom)
        }
    }

    /// White card: photo on the top edge, name, username and the code.
    private var cardView: some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 50)
            if displayName?.isEmpty == false {
                Text("@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(Color.black.opacity(0.5))
            }
            ZStack {
                if let image = qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.top, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR code for @\(username)")
            Text("Scan to message me on Relay")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.black.opacity(0.45))
                .padding(.top, 14)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
        }
        .overlay(alignment: .top) {
            AvatarView(name: displayName ?? username, size: 84, imageData: avatarData)
                .padding(5)
                .background(.white, in: .circle)
                .offset(y: -42)
                .accessibilityHidden(true)
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                if let photo {
                    Button {
                        presetId = "photo"
                    } label: {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 30, height: 30)
                            .clipShape(.circle)
                            .overlay(Circle().strokeBorder(.white, lineWidth: usesPhoto ? 3 : 1)
                                .opacity(usesPhoto ? 1 : 0.5))
                    }
                    .accessibilityLabel("Profile photo")
                    .accessibilityAddTraits(usesPhoto ? .isSelected : [])
                }
                ForEach(QRPreset.all) { option in
                    Button {
                        presetId = option.id
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: [option.topColor, option.botColor],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(.white, lineWidth: option.id == selectedId ? 3 : 1)
                                .opacity(option.id == selectedId ? 1 : 0.5))
                    }
                    .accessibilityLabel(option.id.capitalized)
                    .accessibilityAddTraits(option.id == selectedId ? .isSelected : [])
                }
            }

            HStack(spacing: 12) {
                actionButton(title: "Share", systemImage: "square.and.arrow.up") { showingShare = true }
                    .disabled(shareCard == nil)
                actionButton(title: linkCopied ? "Copied" : "Copy Link",
                             systemImage: linkCopied ? "checkmark" : "link") {
                    SecurePasteboard.copy(link)
                    linkCopied = true
                    Task { try? await Task.sleep(for: .seconds(2)); linkCopied = false }
                }
            }

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
                    HStack(spacing: 6) {
                        if generatingInvite { ProgressView().tint(.white) }
                        Text("Create a one-time invite link")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .disabled(generatingInvite)
            }
        }
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .glassCompat(in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func regenerate() async {
        let user = username
        let p = preset
        let title = name
        let subtitle = displayName?.isEmpty == false ? "@\(username)" : nil
        let avatar = photo
        let withPhoto = usesPhoto
        if withPhoto, photoColor == nil, let avatar {
            photoColor = await Task.detached(priority: .userInitiated) { qrModuleColor(from: avatar) }.value
        }
        let m = moduleColor
        let qr = await Task.detached(priority: .userInitiated) {
            makeQRImage(username: user, size: 900, modR: m.r, modG: m.g, modB: m.b)
        }.value
        qrImage = qr
        shareCard = await Task.detached(priority: .userInitiated) {
            renderShareCard(title: title, subtitle: subtitle, avatar: avatar, qrImage: qr,
                            backdrop: withPhoto ? avatar : nil,
                            topR: p.tR, topG: p.tG, topB: p.tB,
                            botR: p.bR, botG: p.bG, botB: p.bB)
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

    // The background stays white so the code scans with any module colour.
    let colorFilter = CIFilter.falseColor()
    colorFilter.inputImage = scaled
    colorFilter.color0     = CIColor(red: modR, green: modG, blue: modB)  // modules
    colorFilter.color1     = CIColor(red: 1, green: 1, blue: 1)            // background

    guard let coloured = colorFilter.outputImage,
          let cgImage  = context.createCGImage(coloured, from: coloured.extent)
    else { return nil }

    return UIImage(cgImage: cgImage)
}

// MARK: - Photo colour

/// A dark, saturated shade of the photo's average colour: dark enough to scan
/// on white, close enough to read as the photo's colour.
nonisolated private func qrModuleColor(from image: UIImage) -> (r: Double, g: Double, b: Double)? {
    guard let input = CIImage(image: image) else { return nil }
    let filter = CIFilter.areaAverage()
    filter.inputImage = input
    filter.extent = input.extent
    guard let output = filter.outputImage else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    let shade = UIColor(hue: h, saturation: s < 0.15 ? s : max(s, 0.65), brightness: 0.3, alpha: 1)
    var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
    shade.getRed(&r, green: &g, blue: &bl, alpha: &a)
    return (Double(r), Double(g), Double(bl))
}

/// The photo blurred and darkened like the call screens, for the share image.
nonisolated private func blurredBackdrop(_ image: UIImage, size: CGSize) -> UIImage? {
    guard let input = CIImage(image: image) else { return nil }
    let scale = max(size.width / input.extent.width, size.height / input.extent.height)
    let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).clampedToExtent()
    let blur = CIFilter.gaussianBlur()
    blur.inputImage = scaled
    blur.radius = 60
    let controls = CIFilter.colorControls()
    controls.inputImage = blur.outputImage
    controls.saturation = 2.2
    controls.brightness = -0.05
    guard let output = controls.outputImage else { return nil }
    let w = input.extent.width * scale, h = input.extent.height * scale
    let crop = CGRect(x: (w - size.width) / 2, y: (h - size.height) / 2, width: size.width, height: size.height)
    guard let cg = CIContext().createCGImage(output, from: crop) else { return nil }
    return UIImage(cgImage: cg)
}

// MARK: - Share card rendering

// Renders the on-screen card over its gradient as one image for sharing.
nonisolated private func renderShareCard(
    title: String, subtitle: String?, avatar: UIImage?, qrImage: UIImage?, backdrop: UIImage?,
    topR: Double, topG: Double, topB: Double,
    botR: Double, botG: Double, botB: Double
) -> UIImage? {
    let width: CGFloat = 1080
    let margin: CGFloat = 90
    let cardW = width - margin * 2
    let pad: CGFloat = 70
    let avatarD: CGFloat = 200
    let qrSize = cardW - pad * 2
    let titleY: CGFloat = margin + avatarD / 2 + 130
    let cardTop = margin + avatarD / 2
    let subtitleH: CGFloat = subtitle == nil ? 0 : 50
    let qrY = titleY + 70 + subtitleH + 30
    let captionY = qrY + qrSize + 34
    let cardBottom = captionY + 40 + 60
    let height = cardBottom + margin

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
        let cg = ctx.cgContext
        let colors = [
            UIColor(red: topR, green: topG, blue: topB, alpha: 1).cgColor,
            UIColor(red: botR, green: botG, blue: botB, alpha: 1).cgColor,
        ] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        if let backdrop, let blurred = blurredBackdrop(backdrop, size: CGSize(width: width, height: height)) {
            blurred.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.withAlphaComponent(0.38).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }

        let card = CGRect(x: margin, y: cardTop, width: cardW, height: cardBottom - cardTop)
        UIColor.white.setFill()
        UIBezierPath(roundedRect: card, cornerRadius: 80).fill()

        // Photo on the card's top edge, in a white ring.
        let ring = CGRect(x: (width - avatarD - 24) / 2, y: margin - 12, width: avatarD + 24, height: avatarD + 24)
        UIBezierPath(ovalIn: ring).fill()
        let avatarRect = ring.insetBy(dx: 12, dy: 12)
        cg.saveGState()
        UIBezierPath(ovalIn: avatarRect).addClip()
        if let avatar {
            let scale = max(avatarRect.width / avatar.size.width, avatarRect.height / avatar.size.height)
            let size = CGSize(width: avatar.size.width * scale, height: avatar.size.height * scale)
            avatar.draw(in: CGRect(x: avatarRect.midX - size.width / 2, y: avatarRect.midY - size.height / 2,
                                   width: size.width, height: size.height))
        } else {
            UIColor(red: topR, green: topG, blue: topB, alpha: 1).setFill()
            UIBezierPath(ovalIn: avatarRect).fill()
            let initial = String(title.trimmingCharacters(in: CharacterSet(charactersIn: "@")).prefix(1)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 90, weight: .semibold), .foregroundColor: UIColor.white]
            let sz = initial.size(withAttributes: attrs)
            initial.draw(at: CGPoint(x: avatarRect.midX - sz.width / 2, y: avatarRect.midY - sz.height / 2), withAttributes: attrs)
        }
        cg.restoreGState()

        func centered(_ text: String, y: CGFloat, font: UIFont, color: UIColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: (width - size.width) / 2, y: y), withAttributes: attrs)
        }
        centered(title, y: titleY, font: .systemFont(ofSize: 60, weight: .bold), color: .black)
        if let subtitle {
            centered(subtitle, y: titleY + 76, font: .systemFont(ofSize: 38), color: UIColor.black.withAlphaComponent(0.5))
        }

        let qrRect = CGRect(x: (width - qrSize) / 2, y: qrY, width: qrSize, height: qrSize)
        qrImage?.draw(in: qrRect)

        centered("Scan to message me on Relay", y: captionY, font: .systemFont(ofSize: 34, weight: .medium),
                 color: UIColor.black.withAlphaComponent(0.45))
    }
}

// MARK: - Screenshot-hidden container

extension View {
    /// Hosts the view inside a UITextField's secure-entry canvas, which iOS
    /// omits from screenshots and screen recordings.
    ///
    /// The content is re-hosted in its own UIHostingController and does not
    /// inherit environment values or objects; callers must re-inject them.
    /// Pass `fillsProposal` for content that should take the offered space
    /// (e.g. a ScrollView) rather than its ideal height.
    @ViewBuilder
    func hiddenInScreenshots(_ active: Bool = true, fillsProposal: Bool = false) -> some View {
        if active {
            // Only wrap when active: the reparenting can clip the content.
            ScreenshotHiddenContainer(active: true, fillsProposal: fillsProposal) { self }
        } else {
            self
        }
    }
}

private struct ScreenshotHiddenContainer<Content: View>: UIViewRepresentable {
    var active: Bool
    var fillsProposal: Bool
    var content: Content

    init(active: Bool = true, fillsProposal: Bool = false, @ViewBuilder content: () -> Content) {
        self.active = active
        self.fillsProposal = fillsProposal
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(rootView: content)
        // The outer layout already applied safe-area and keyboard insets.
        if fillsProposal { coord.hosting.safeAreaRegions = [] }
        return coord
    }

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

        // The secure canvas is the text field's first (private) subview. If it
        // isn't there, show the content normally.
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
        // The field is created secure so the canvas exists; this only toggles
        // whether it is captured.
        context.coordinator.secureField.isSecureTextEntry = active
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        if fillsProposal, let width = proposal.width, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
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

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var scanned = false
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var unrecognized = false

    var body: some View {
        NavigationStack {
            Group {
                if cameraStatus == .denied || cameraStatus == .restricted {
                    ContentUnavailableView {
                        Label("Camera Access Needed", systemImage: "camera.fill")
                    } description: {
                        Text("Allow Relay to use the camera in Settings to scan QR codes.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if !DataScannerViewController.isSupported {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("This device does not support the QR scanner.")
                    )
                } else if cameraStatus == .notDetermined {
                    ProgressView()
                } else {
                    DataScannerRepresentable(onScan: handleScan)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            Text(unrecognized
                                 ? "That QR code isn't a Relay code."
                                 : "Point the camera at a Relay QR code.")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: .capsule)
                                .padding(.bottom, 32)
                        }
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                guard cameraStatus == .notDetermined else { return }
                _ = await AVCaptureDevice.requestAccess(for: .video)
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func handleScan(_ payload: String) {
        guard !scanned else { return }
        switch RelayQRPayload(payload) {
        case .username(let username):
            scanned = true
            dismiss()
            onScan(username)
        case .contactInvite(let token):
            scanned = true
            dismiss()
            model.pendingContactInviteToken = token
        case .groupInvite(let token):
            scanned = true
            dismiss()
            model.pendingGroupInviteToken = token
        case nil:
            unrecognized = true
        }
    }
}

/// What a scanned Relay QR code points at.
enum RelayQRPayload: Equatable {
    case username(String)
    case contactInvite(String)
    /// `<token>` or `<token>#<fragment-key>`, as `pendingGroupInviteToken` expects.
    case groupInvite(String)

    init?(_ payload: String) {
        if let url = URL(string: payload) {
            let parts = Array(url.pathComponents.dropFirst())
            if url.scheme == "relay", let host = url.host, let value = parts.first, !value.isEmpty {
                // relay://add/<username>, relay://contact/<token>, relay://join/<token>#<key>
                switch host {
                case "add": self = .username(value); return
                case "contact": self = .contactInvite(value); return
                case "join": self = .groupInvite(Self.withFragment(value, url)); return
                default: break
                }
            }
            if url.host == "relaymsg.app", parts.count >= 2, !parts[1].isEmpty {
                // https://relaymsg.app/{add|c|g}/<value>
                switch parts[0] {
                case "add": self = .username(parts[1]); return
                case "c": self = .contactInvite(parts[1]); return
                case "g": self = .groupInvite(Self.withFragment(parts[1], url)); return
                default: break
                }
            }
        }
        // Legacy relay:<username>
        if payload.hasPrefix("relay:"), !payload.hasPrefix("relay://") {
            let name = String(payload.dropFirst("relay:".count))
            if !name.isEmpty { self = .username(name); return }
        }
        return nil
    }

    private static func withFragment(_ token: String, _ url: URL) -> String {
        guard let fragment = url.fragment, !fragment.isEmpty else { return token }
        return "\(token)#\(fragment)"
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

        // Accept a code as soon as it's recognised rather than waiting for a tap.
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems { deliver(item) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver(item)
        }

        private func deliver(_ item: RecognizedItem) {
            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue, !payload.isEmpty
            else { return }
            onScan(payload)
        }
    }
}
