//
//  SafeImage.swift
//  Relay
//
//  Decodes images that arrive from other people. A small file can describe a
//  huge bitmap (a 30,000 × 30,000 PNG compresses to almost nothing) or
//  thousands of animation frames, and `UIImage(data:)` would decode all of it
//  when drawn, getting the app killed every time the chat opens. Everything
//  here reads the header first and decodes through ImageIO's downsampler.
//

import ImageIO
import UIKit

nonisolated enum SafeImage {
    /// Images claiming more pixels than this aren't decoded at all.
    static let maxSourcePixels = 200_000_000
    /// Longest edge for a full-screen view.
    static let fullScreenPixelSize = 4096
    /// Longest edge for a bubble in the chat.
    static let inlinePixelSize = 1600

    /// Pixel size from the header, without decoding. Nil if not an image.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Decodes `data` with its longest edge at most `maxPixelSize`, applying
    /// the EXIF orientation. Nil if it isn't an image or claims too many pixels.
    static func image(from data: Data, maxPixelSize: Int = fullScreenPixelSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              isReasonable(source, index: 0)
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Frames of an animated image, each downsampled, within a total memory
    /// budget. A single-frame image comes back as one frame.
    static func animation(from data: Data, maxPixelSize: Int = 480,
                          maxFrames: Int = 300, maxBytes: Int = 120_000_000) -> (frames: [UIImage], duration: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let count = min(CGImageSourceGetCount(source), maxFrames)
        guard count > 0 else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        var frames: [UIImage] = []
        var duration = 0.0
        var bytes = 0
        for i in 0..<count {
            guard isReasonable(source, index: i),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, i, options) else { continue }
            bytes += cg.bytesPerRow * cg.height
            if bytes > maxBytes { break }
            frames.append(UIImage(cgImage: cg))
            duration += frameDelay(source, index: i)
        }
        return frames.isEmpty ? nil : (frames, duration)
    }

    /// Up to `count` frames spread evenly through an animation (or the one
    /// frame of a still image), each downsampled.
    static func sampledFrames(from data: Data, count: Int, maxPixelSize: Int) -> [CGImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return [] }
        let total = CGImageSourceGetCount(source)
        guard total > 0, count > 0 else { return [] }
        let step = max(1, total / count)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return stride(from: 0, to: total, by: step).prefix(count).compactMap { index in
            guard isReasonable(source, index: index) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, index, options)
        }
    }

    /// A received profile or group photo as a small JPEG: bounded size for
    /// every place that shows it (widgets, notifications, the watch) and no
    /// metadata from the sender's file. Nil if it isn't a usable image.
    static func avatarJPEG(from data: Data, maxPixelSize: Int = 512) -> Data? {
        image(from: data, maxPixelSize: maxPixelSize)?.jpegData(compressionQuality: 0.85)
    }

    /// Whether `data` is a decodable image (header only).
    static func isImage(_ data: Data) -> Bool { pixelSize(of: data) != nil }

    private static func isReasonable(_ source: CGImageSource, index: Int) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return w > 0 && h > 0 && w.multipliedReportingOverflow(by: h).partialValue <= maxSourcePixels
            && !w.multipliedReportingOverflow(by: h).overflow
    }

    private static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
            ?? png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
            ?? png?[kCGImagePropertyAPNGDelayTime] as? Double
            ?? 0.1
        return delay.isFinite ? min(max(delay, 0.02), 10) : 0.1
    }
}
