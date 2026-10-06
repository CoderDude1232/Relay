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
        writeState(active: false)
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

        let frameURL = containerURL.appendingPathComponent(Self.frameFilename)
        let tempURL = containerURL.appendingPathComponent("\(Self.frameFilename).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: frameURL.path) {
                _ = try FileManager.default.replaceItemAt(frameURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: frameURL)
            }
            lastFrameSentAt = now
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
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
        let url = containerURL.appendingPathComponent(Self.stateFilename)
        let state: [String: Any] = [
            "active": active,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        (state as NSDictionary).write(to: url, atomically: true)
    }

    private func removeLatestFrame() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else { return }
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(Self.frameFilename))
    }
}
