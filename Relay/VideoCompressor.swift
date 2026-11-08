//
//  VideoCompressor.swift
//  Relay
//
//  Re-encodes a picked video to HEVC on the hardware encoder before sending:
//  at most 1080p, at a bitrate that fits the relay's size cap. A 4K60 clip
//  shrinks around tenfold, so it uploads and downloads that much faster.
//  Nothing from the source's metadata is copied, so location and camera
//  details are left behind. HDR stays HDR (10-bit, the source's colour).
//

import AVFoundation
import VideoToolbox

nonisolated enum VideoCompressor {
    enum Failure: Error { case unreadable, tooLong, encodeFailed }

    /// Best quality aimed for; shorter clips get this, long ones less.
    private static let targetBitrate = 6_000_000.0
    private static let lowestBitrate = 500_000.0
    private static let audioBitrate = 128_000.0

    /// Compresses `input` into a new temp file of at most `maxBytes`.
    /// `progress` gets 0 to 1 as frames are encoded.
    static func compress(_ input: URL, maxBytes: Int,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.unreadable }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.unreadable }
        let (naturalSize, transform, frameRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let formats = try await videoTrack.load(.formatDescriptions)
        let isHDR = try await videoTrack.load(.mediaCharacteristics).contains(.containsHDRVideo)

        // Leave room for the container and the 28 bytes of encryption.
        let budget = Double(maxBytes) * 0.92 * 8 / duration - (audioTrack == nil ? 0 : audioBitrate)
        guard budget >= lowestBitrate else { throw Failure.tooLong }
        let bitrate = min(targetBitrate, budget)
        // Low bitrates look better at a smaller size.
        let longEdge: CGFloat = bitrate < 2_500_000 ? 1280 : 1920
        let scale = min(1, longEdge / max(naturalSize.width, naturalSize.height))
        // Even dimensions for the encoder.
        let width = Int((naturalSize.width * scale / 2).rounded()) * 2
        let height = Int((naturalSize.height * scale / 2).rounded()) * 2

        let output = TempMediaFiles.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let pixelFormat = isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw Failure.unreadable }
        reader.add(videoOut)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate > 0 ? frameRate : 30,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        compression[AVVideoProfileLevelKey] = isHDR
            ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
            : kVTProfileLevel_HEVC_Main_AutoLevel as String
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let colour = colourProperties(formats.first, hdr: isHDR) { videoSettings[AVVideoColorPropertiesKey] = colour }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw Failure.encodeFailed }
        writer.add(videoIn)

        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                audioOut = out
                audioIn = input
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            TempMediaFiles.remove(output)
            throw Failure.encodeFailed
        }
        writer.startSession(atSourceTime: .zero)

        let pumpVideo = Pump(reader: videoOut, writer: videoIn, duration: duration, progress: progress)
        let pumpAudio = audioOut.flatMap { out in audioIn.map { Pump(reader: out, writer: $0, duration: duration, progress: nil) } }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pumpVideo.run() }
            if let pumpAudio { group.addTask { await pumpAudio.run() } }
        }

        if Task.isCancelled || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            TempMediaFiles.remove(output)
            throw Task.isCancelled ? CancellationError() : Failure.encodeFailed
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            TempMediaFiles.remove(output)
            throw Failure.encodeFailed
        }
        progress(1)
        return output
    }

    /// The source's colour, so HDR (HLG or PQ, BT.2020) and SDR both look right.
    private static func colourProperties(_ format: CMFormatDescription?, hdr: Bool) -> [String: Any]? {
        let ext = format.flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] }
        let primaries = ext?[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transfer = ext?[kCMFormatDescriptionExtension_TransferFunction] as? String
        let matrix = ext?[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        if let primaries, let transfer, let matrix {
            return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
        }
        if hdr {
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    /// Moves samples from a reader output to a writer input as fast as the
    /// encoder takes them.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReaderOutput
        let writer: AVAssetWriterInput
        let duration: Double
        let progress: (@Sendable (Double) -> Void)?
        private let queue = DispatchQueue(label: "app.relaymsg.video-compress")

        init(reader: AVAssetReaderOutput, writer: AVAssetWriterInput, duration: Double,
             progress: (@Sendable (Double) -> Void)?) {
            self.reader = reader
            self.writer = writer
            self.duration = duration
            self.progress = progress
        }

        private let lock = NSLock()
        private var cancelled = false
        private var isCancelled: Bool { lock.withLock { cancelled } }

        func run() async {
            await withTaskCancellationHandler {
                await pump()
            } onCancel: {
                lock.withLock { cancelled = true }
            }
        }

        private func pump() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var finished = false
                var lastReport = -1.0
                writer.requestMediaDataWhenReady(on: queue) { [self] in
                    while writer.isReadyForMoreMediaData, !finished {
                        guard !isCancelled, let sample = reader.copyNextSampleBuffer() else {
                            finished = true
                            writer.markAsFinished()
                            done.resume()
                            return
                        }
                        writer.append(sample)
                        if let progress {
                            let fraction = CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration
                            if fraction - lastReport >= 0.01 {
                                lastReport = fraction
                                progress(min(0.99, max(0, fraction)))
                            }
                        }
                    }
                }
            }
        }
    }
}
