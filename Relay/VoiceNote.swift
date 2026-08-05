//
//  VoiceNote.swift
//  Relay
//
//  Microphone capture and playback for voice messages. Recording writes a
//  short AAC/m4a file to the temporary directory; the bytes are handed to the
//  normal attachment pipeline (AES-GCM sealed, uploaded, cached) and the temp
//  file is deleted — plaintext audio never persists to disk unencrypted.
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

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var ticker: Task<Void, Never>?

    /// Requests mic permission (once) and begins recording. Returns false if
    /// permission was denied or the audio session couldn't start.
    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record()
            recorder = rec
            fileURL = url
            elapsed = 0
            isRecording = true
            startTicking()
            return true
        } catch {
            return false
        }
    }

    /// Stops recording and returns the finished clip as a pending attachment,
    /// or nil if it was too short (< 1s) or couldn't be read.
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

    /// Aborts recording and discards the clip.
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let recorder = self.recorder, recorder.isRecording else { break }
                self.elapsed = recorder.currentTime
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}

/// Plays back a single voice message. One instance per voice bubble; the
/// decrypted audio bytes are supplied on first play and held only in memory.
@Observable
final class VoicePlayer {
    private(set) var isPlaying = false
    /// Playback position as a fraction 0...1 of the clip's duration.
    private(set) var progress: Double = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// Loads the audio (without playing) so the duration can be shown.
    func prepare(_ data: Data) {
        guard player == nil else { return }
        player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
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
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let player = self.player else { break }
                if player.isPlaying {
                    self.progress = self.duration > 0 ? player.currentTime / self.duration : 0
                } else {
                    // Reached the end (natural finish): reset for replay.
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

/// Formats a duration as m:ss for compact labels.
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
