//
//  AIAssistant.swift
//  Relay
//
//  On-device summaries, smart replies and transcription (FoundationModels and
//  SFSpeechRecognizer). Nothing leaves the device.
//

import Foundation
import FoundationModels
import SecureStorage
import Speech

// MARK: - Assistant

/// Stateless wrapper around FoundationModels and SFSpeechRecognizer.
@available(iOS 26.0, *)
actor AIAssistant {

    static let shared = AIAssistant()

    nonisolated var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: Summarisation

    /// Returns a 2–4 sentence plain-text summary of the supplied messages.
    /// Throws if the model is unavailable or the prompt is too long.
    func summarize(_ messages: [StoredMessage]) async throws -> String {
        guard isAvailable else { throw AIError.modelUnavailable }
        let body = messages
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(40)
            .map { ($0.isOutgoing ? "You" : "Them") + ": " + $0.body }
            .joined(separator: "\n")
        guard !body.isEmpty else { throw AIError.noContent }
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: "Summarize the following private chat in 2-4 concise sentences. " +
                "Don't add filler. Output only the summary.\n\n\(body)"
        )
        return response.content
    }

    // MARK: Smart replies

    /// Generates up to 3 short smart-reply suggestions for the last message.
    func suggestReplies(to message: StoredMessage, peerName: String) async throws -> [String] {
        guard isAvailable else { throw AIError.modelUnavailable }
        let prompt = "\"\(message.body)\"\n\n" +
            "Suggest exactly 3 brief, natural reply options for this message. " +
            "Output only the 3 options, one per line, no numbering, no quotes."
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        let lines = response.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(lines.prefix(3))
    }

    // MARK: Voice transcription

    /// True only when the current locale's recognizer can run fully on-device.
    /// Hide "Transcribe" when false; we never fall back to server recognition.
    nonisolated static var isOnDeviceTranscriptionAvailable: Bool {
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.supportsOnDeviceRecognition && recognizer.isAvailable
    }

    /// Transcribes m4a/AAC audio on-device. Throws
    /// `AIError.transcriptionUnavailable` rather than sending audio to Apple.
    func transcribe(audioData: Data, contentType: String) async throws -> String {
        let ext = contentType.contains("m4a") ? "m4a" : "aac"
        let tmp = try TempMediaFiles.write(audioData, originalName: nil, fallbackExtension: ext)
        defer { TempMediaFiles.remove(tmp) }
        return try await transcribe(url: tmp)
    }

    private func transcribe(url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw AIError.transcriptionUnavailable
        }
        let authorized = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard authorized else { throw AIError.transcriptionDenied }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
enum AIError: LocalizedError {
    case modelUnavailable
    case noContent
    case transcriptionUnavailable
    case transcriptionDenied

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "Apple Intelligence is not available on this device."
        case .noContent: "No messages to summarize."
        case .transcriptionUnavailable: "On-device speech recognition is not available for this language."
        case .transcriptionDenied: "Speech recognition permission was denied."
        }
    }
}
