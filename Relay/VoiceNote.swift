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

    private var recorder: AVAudioRecorder?
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
        guard let recorder, let fileURL else { cancel(); return nil }
        let duration = recorder.currentTime
        recorder.stop()
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

    func cancel() {
        recorder?.stop()
        if let fileURL { cleanup(fileURL) }
        teardown()
    }

    private func teardown() {
        stopTicking()
        recorder = nil
        fileURL = nil
        isRecording = false
        isPaused = false
        levels = []
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
