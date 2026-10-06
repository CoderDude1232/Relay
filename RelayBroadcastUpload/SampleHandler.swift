//
//  SampleHandler.swift
//  RelayBroadcastUpload
//

import CoreImage
import ReplayKit
import UIKit

final class SampleHandler: RPBroadcastSampleHandler {
    private static let appGroupId = "group.app.relaymsg"
    private static let frameFilename = "RelayBroadcastFrame.jpg"
    private static let stateFilename = "RelayBroadcastState.plist"

    private let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    private var lastFrameSentAt = Date.distantPast
    private let minimumFrameInterval: TimeInterval = 1.0 / 12.0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        writeState(active: true)
    }

    override func broadcastPaused() {
        writeState(active: false)
    }

    override func broadcastResumed() {
        writeState(active: true)
    }

    override func broadcastFinished() {
        // Removes the frame AND the state file — nothing is left behind.
        removeLatestFrame()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        publishVideoFrame(sampleBuffer)
    }

    private func publishVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameSentAt) >= minimumFrameInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)
        else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = scaledImage(image, maxDimension: 1280)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: 0.62) else { return }

        // A screen frame can show anything (messages, codes, photos): write it
        // with complete Data Protection (unreadable while locked), atomically
        // (temp + rename), and keep it out of backups. It is deleted when the
        // broadcast ends.
        var frameURL = containerURL.appendingPathComponent(Self.frameFilename)
        do {
            try data.write(to: frameURL, options: [.atomic, .completeFileProtection])
            Self.excludeFromBackup(&frameURL)
            lastFrameSentAt = now
        } catch {
            // Locked or out of space: drop this frame.
        }
    }

    private static func excludeFromBackup(_ url: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func scaledImage(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func writeState(active: Bool) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else { return }
        var url = containerURL.appendingPathComponent(Self.stateFilename)
        let state: [String: Any] = [
            "active": active,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Self.excludeFromBackup(&url)
    }

    /// Deletes the last frame (and any temp file an older build left behind).
    private func removeLatestFrame() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: containerURL.appendingPathComponent(Self.frameFilename))
        try? fm.removeItem(at: containerURL.appendingPathComponent("\(Self.frameFilename).tmp"))
        try? fm.removeItem(at: containerURL.appendingPathComponent(Self.stateFilename))
    }
}
