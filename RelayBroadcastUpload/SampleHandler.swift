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

    /// Written by the app while a video call wants the screen; see stopIfUnwanted.
    private static let wantedFilename = "RelayBroadcastWanted"

    private let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    private var lastFrameSentAt = Date.distantPast
    private let minimumFrameInterval: TimeInterval = 1.0 / 12.0
    private var startedAt = Date()
    private var lastWantedCheck = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedAt = Date()
        writeState(active: true)
    }

    override func broadcastPaused() {
        writeState(active: false)
    }

    override func broadcastResumed() {
        writeState(active: true)
    }

    override func broadcastFinished() {
        removeLatestFrame()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard !stopIfUnwanted() else { return }
        publishVideoFrame(sampleBuffer)
    }

    /// Ends the broadcast once no Relay call wants it (the call ended, the user
    /// stopped sharing, or it was started from Control Center outside a call),
    /// instead of capturing whatever is on screen until the user notices.
    /// Returns true when it has stopped.
    private func stopIfUnwanted() -> Bool {
        let now = Date()
        // A few seconds' grace at the start, for the app to say it wants it.
        guard now.timeIntervalSince(startedAt) > 5, now.timeIntervalSince(lastWantedCheck) >= 1 else { return false }
        lastWantedCheck = now
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId),
              !FileManager.default.fileExists(atPath: containerURL.appendingPathComponent(Self.wantedFilename).path)
        else { return false }
        removeLatestFrame()
        finishBroadcastWithError(NSError(domain: "app.relaymsg.broadcast", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Screen sharing stopped because you're not sharing in a Relay video call.",
        ]))
        return true
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

        // A screen frame can show anything, so it is written atomically with complete
        // file protection, excluded from backup, and deleted when the broadcast ends.
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

    /// Deletes the last frame and any leftover temp file.
    private func removeLatestFrame() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: containerURL.appendingPathComponent(Self.frameFilename))
        try? fm.removeItem(at: containerURL.appendingPathComponent("\(Self.frameFilename).tmp"))
        try? fm.removeItem(at: containerURL.appendingPathComponent(Self.stateFilename))
    }
}
