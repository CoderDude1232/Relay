//
//  MediaSanitizer.swift
//  Relay
//
//  Strips what a photo or video file says about where and how it was taken
//  (GPS, camera details, edit history) before it's sent. Photos are re-encoded;
//  videos are rewritten without re-encoding, minus location metadata.
//

import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum MediaSanitizer {
    /// Relay Supporters send photos at full resolution.
    static let originalPixelSize = 16_384

    /// A photo as a metadata-free JPEG (GIFs keep their bytes so they still
    /// animate). Nil if it isn't a usable image. `original` keeps the full
    /// resolution and near-lossless quality (Relay Supporter).
    static func photo(_ data: Data, original: Bool = false) -> (data: Data, contentType: String, width: Int, height: Int)? {
        if isGIF(data) {
            let size = SafeImage.pixelSize(of: data) ?? .zero
            return (data, "image/gif", Int(size.width), Int(size.height))
        }
        let maxPixelSize = original ? originalPixelSize : SafeImage.fullScreenPixelSize
        guard let image = SafeImage.image(from: data, maxPixelSize: maxPixelSize) else { return nil }
        let width = Int(image.size.width * image.scale), height = Int(image.size.height * image.scale)
        // Keep transparency (a cut-out, a screenshot of a sticker) as PNG.
        if isPNG(data), hasAlpha(image), let png = image.pngData() {
            return (png, "image/png", width, height)
        }
        // HEIC is about half the size of a JPEG that looks the same, so it
        // uploads and downloads in half the time.
        if let heic = heicData(image, quality: original ? 0.95 : 0.8) {
            return (heic, "image/heic", width, height)
        }
        guard let jpeg = image.jpegData(compressionQuality: original ? 0.97 : 0.9) else { return nil }
        return (jpeg, "image/jpeg", width, height)
    }

    /// Encoded from pixels only, so no metadata comes along.
    private static func heicData(_ image: UIImage, quality: Double) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)
        else { return nil }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation.rawValue,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        switch image.cgImage?.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        default: false
        }
    }

    private static func isPNG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?
        else { return false }
        return UTType(type)?.conforms(to: .png) == true
    }

    static func isGIF(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?
        else { return false }
        return UTType(type)?.conforms(to: .gif) == true
    }

    /// A video rewritten without location metadata (no re-encode). Nil if it
    /// can't be read; callers don't send the original instead.
    static func video(_ data: Data, contentType: String) async -> Data? {
        let isQuickTime = contentType == "video/quicktime"
        guard let input = try? TempMediaFiles.write(data, originalName: nil, fallbackExtension: isQuickTime ? "mov" : "mp4")
        else { return nil }
        defer { TempMediaFiles.remove(input) }
        return await video(at: input, quickTime: isQuickTime)
    }

    /// The same, from a file (a picked video is never read whole first).
    static func video(at input: URL, quickTime isQuickTime: Bool) async -> Data? {
        let ext = isQuickTime ? "mov" : "mp4"
        let output = TempMediaFiles.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        defer { TempMediaFiles.remove(output) }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        session.metadataItemFilter = .forSharing()
        do {
            try await session.export(to: output, as: isQuickTime ? .mov : .mp4)
        } catch {
            return nil
        }
        return try? Data(contentsOf: output)
    }
}

private extension CGImagePropertyOrientation {
    nonisolated init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
