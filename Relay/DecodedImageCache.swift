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
    /// Longest edge of cached images in pixels: enough for a 260pt card at 3x.
    private static let maxPixelSize = 800

    private static let cache: NSCache<NSData, UIImage> = {
        let c = NSCache<NSData, UIImage>()
        c.countLimit = 200
        return c
    }()

    /// Decoded, downsampled image for `data`, cached by content. Nil if not an image.
    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let decoded = downsample(data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }

    private static func downsample(_ data: Data) -> UIImage? {
        SafeImage.image(from: data, maxPixelSize: maxPixelSize)
    }
}
