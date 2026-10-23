//
//  VoiceNote.swift
//  Relay
//
//  Voice message recording and playback. The temporary m4a is deleted once
//  its bytes go to the attachment pipeline, so plaintext audio doesn't persist.
//

import AVFoundation
import Foundation
import Observation

/// Captures a single voice message. One instance per compose bar.
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    /// Seconds elapsed in the current recording, updated a few times a second.
    private(set) var elapsed: TimeInterval = 0
    private(set) var isPaused = false
    /// Recent input loudness, 0...1, oldest first, for the live waveform.
    private(set) var levels: [Float] = []
    static let levelCount = 36
    /// Every level since the start, for the waveform shown on review.
    private(set) var allLevels: [Float] = []
    /// Stopped and waiting to be played back, sent or deleted.
    private(set) var isReviewing = false
    private(set) var isPreviewPlaying = false
    /// Review playback position, 0...1.
    private(set) var previewProgress: Double = 0

    private var recorder: AVAudioRecorder?
    private var previewPlayer: AVAudioPlayer?
    private var reviewDuration: TimeInterval = 0
    private var fileURL: URL?
    private var ticker: Task<Void, Never>?

    /// Returns false if permission was denied or the audio session failed.
    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            // The protected temp folder: complete file protection, no backups,
            // swept at launch if the app is killed mid-recording.
            let url = TempMediaFiles.directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.record()
            recorder = rec
            fileURL = url
            elapsed = 0
            levels = []
            allLevels = []
            isPaused = false
            isRecording = true
            startTicking()
            return true
        } catch {
            return false
        }
    }

    /// Nil if the clip is under 1s or couldn't be read.
    func finish() -> MessagingService.PendingAttachment? {
        guard let fileURL, recorder != nil || isReviewing else { cancel(); return nil }
        let duration = isReviewing ? reviewDuration : recorder?.currentTime ?? 0
        recorder?.stop()
        teardown()
        defer { cleanup(fileURL) }
        guard duration >= 1, let data = try? Data(contentsOf: fileURL) else { return nil }
        return MessagingService.PendingAttachment(
            data: data, contentType: "audio/m4a", filename: nil, width: 0, height: 0
        )
    }

    func togglePause() {
        guard let recorder else { return }
        if isPaused {
            recorder.record()
        } else {
            recorder.pause()
        }
        isPaused.toggle()
    }

    /// Stops recording and keeps the clip to listen to before sending.
    func stopForReview() {
        guard let recorder, !isReviewing else { return }
        reviewDuration = recorder.currentTime
        elapsed = reviewDuration
        recorder.stop()
        stopTicking()
        self.recorder = nil
        isPaused = false
        isReviewing = true
        previewProgress = 0
    }

    func togglePreview() {
        guard isReviewing, let fileURL else { return }
        if let previewPlayer, previewPlayer.isPlaying {
            previewPlayer.pause()
            isPreviewPlaying = false
            stopTicking()
            return
        }
        if previewPlayer == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            previewPlayer = try? AVAudioPlayer(contentsOf: fileURL)
        }
        guard let previewPlayer else { return }
        if previewProgress >= 0.999 { previewPlayer.currentTime = 0 }
        previewPlayer.play()
        isPreviewPlaying = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let player = self.previewPlayer else { break }
                let total = max(player.duration, 0.01)
                if player.isPlaying {
                    self.previewProgress = min(1, player.currentTime / total)
                } else {
                    self.previewProgress = 1
                    self.isPreviewPlaying = false
                    break
                }
            }
        }
    }

    func cancel() {
        recorder?.stop()
        if let fileURL { cleanup(fileURL) }
        teardown()
    }

    private func teardown() {
        stopTicking()
        recorder = nil
        previewPlayer?.stop()
        previewPlayer = nil
        fileURL = nil
        isRecording = false
        isPaused = false
        isReviewing = false
        isPreviewPlaying = false
        previewProgress = 0
        levels = []
        allLevels = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let recorder = self.recorder else { break }
                guard recorder.isRecording else { continue }
                self.elapsed = recorder.currentTime
                recorder.updateMeters()
                // -50 dB and below reads as silence.
                let power = recorder.averagePower(forChannel: 0)
                let level = max(0.08, min(1, (power + 50) / 50))
                self.levels.append(level)
                self.allLevels.append(level)
                if self.levels.count > Self.levelCount { self.levels.removeFirst(self.levels.count - Self.levelCount) }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}

/// One instance per voice bubble. Decrypted audio is held only in memory.
@Observable
final class VoicePlayer {
    private(set) var isPlaying = false
    /// Playback position as a fraction 0...1 of the clip's duration.
    private(set) var progress: Double = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Double = 1.0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// Loads the audio (without playing) so the duration can be shown.
    func prepare(_ data: Data) {
        guard player == nil else { return }
        player = try? AVAudioPlayer(data: data)
        player?.enableRate = true
        player?.prepareToPlay()
        let reported = player?.duration ?? 0
        duration = reported.isFinite && reported > 0 ? reported : 0
    }

    /// Starts or pauses playback of the given audio, loading it lazily.
    func toggle(_ data: Data) {
        prepare(data)
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicking()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.rate = Float(rate)
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    func cycleRate() {
        rate = rate < 1.2 ? 1.5 : rate < 1.8 ? 2.0 : 1.0
        player?.rate = Float(rate)
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let player = self.player else { break }
                if player.isPlaying {
                    self.progress = self.duration > 0 ? min(max(player.currentTime / self.duration, 0), 1) : 0
                } else {
                    // Natural finish: reset for replay.
                    self.isPlaying = false
                    self.progress = 0
                    player.currentTime = 0
                    break
                }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}

/// m:ss
func formatDuration(_ seconds: TimeInterval) -> String {
    // A crafted file can report NaN or an absurd duration; Int() traps on those.
    guard seconds.isFinite else { return "0:00" }
    let total = Int(min(max(seconds, 0), 359_999).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// The one voice message playing in the app. It keeps going when its chat
/// scrolls away or closes (a mini player shows it then), and moves on to the
/// next voice message in the chat when it ends. Decrypted audio stays in
/// memory.
@MainActor
@Observable
final class VoicePlaybackCenter: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlaybackCenter()

    struct Clip: Equatable {
        let attachmentId: String
        let conversationId: String
        let timestamp: Int64
        let title: String
    }

    private(set) var clip: Clip?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Double = 1.0

    /// Finds the voice message after a clip (nil when there's none).
    var nextClip: ((Clip) async -> (Clip, Data)?)?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func isCurrent(_ attachmentId: String) -> Bool { clip?.attachmentId == attachmentId }

    /// Plays `data`, or pauses/resumes it if it's the current clip.
    func toggle(_ clip: Clip, data: Data) {
        if self.clip == clip, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        start(clip, data: data)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func resume() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.rate = Float(rate)
        player.play()
        isPlaying = true
        startTicking()
    }

    func stop() {
        player?.stop()
        player = nil
        clip = nil
        isPlaying = false
        progress = 0
        stopTicking()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func cycleRate() {
        rate = rate < 1.2 ? 1.5 : rate < 1.8 ? 2.0 : 1.0
        player?.rate = Float(rate)
    }

    private func start(_ clip: Clip, data: Data) {
        player?.stop()
        stopTicking()
        guard let next = try? AVAudioPlayer(data: data) else { return }
        next.enableRate = true
        next.delegate = self
        next.prepareToPlay()
        player = next
        let reported = next.duration
        duration = reported.isFinite && reported > 0 ? reported : 0
        progress = 0
        self.clip = clip
        resume()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in await self.finished() }
    }

    private func finished() async {
        isPlaying = false
        stopTicking()
        guard let clip else { return }
        if let (next, data) = await nextClip?(clip) {
            start(next, data: data)
        } else {
            stop()
        }
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let player = self.player, player.isPlaying else { break }
                self.progress = self.duration > 0 ? min(max(player.currentTime / self.duration, 0), 1) : 0
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}
