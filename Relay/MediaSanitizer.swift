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
    /// A photo as a metadata-free JPEG (GIFs keep their bytes so they still
    /// animate). Nil if it isn't a usable image.
    static func photo(_ data: Data) -> (data: Data, contentType: String, width: Int, height: Int)? {
        if isGIF(data) {
            let size = SafeImage.pixelSize(of: data) ?? .zero
            return (data, "image/gif", Int(size.width), Int(size.height))
        }
        guard let image = SafeImage.image(from: data, maxPixelSize: SafeImage.fullScreenPixelSize),
              let jpeg = image.jpegData(compressionQuality: 0.9)
        else { return nil }
        return (jpeg, "image/jpeg", Int(image.size.width * image.scale), Int(image.size.height * image.scale))
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
