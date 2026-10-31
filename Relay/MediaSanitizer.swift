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
        guard let jpeg = image.jpegData(compressionQuality: original ? 0.97 : 0.9) else { return nil }
        return (jpeg, "image/jpeg", width, height)
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
        let ext = isQuickTime ? "mov" : "mp4"
        guard let input = try? TempMediaFiles.write(data, originalName: nil, fallbackExtension: ext) else { return nil }
        let output = TempMediaFiles.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        defer {
            TempMediaFiles.remove(input)
            TempMediaFiles.remove(output)
        }
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
