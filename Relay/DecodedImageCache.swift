//
//  DecodedImageCache.swift
//  Relay
//
//  Decodes small on-screen images (avatars, compose previews) once and keeps
//  the decoded, downsampled bitmap, so SwiftUI view bodies don't re-run
//  `UIImage(data:)` and a full JPEG/PNG/HEIC decode on every render.
//

import ImageIO
import UIKit

enum DecodedImageCache {
    /// Longest edge, in pixels, of cached images — enough for a 260pt card at
    /// 3x, far smaller than a full-resolution camera photo.
    private static let maxPixelSize = 800

    private static let cache: NSCache<NSData, UIImage> = {
        let c = NSCache<NSData, UIImage>()
        c.countLimit = 200
        return c
    }()

    /// A decoded (and, for large images, downsampled) image for `data`, from
    /// cache when this exact data was seen before. Nil when it isn't an image.
    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let decoded = downsample(data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }

    private static func downsample(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)?.preparingForDisplay()
        }
        return UIImage(cgImage: cg)
    }
}
