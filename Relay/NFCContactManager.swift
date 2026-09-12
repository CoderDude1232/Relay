//
//  NFCContactManager.swift
//  Relay
//
//  Handles reading and writing NFC tags for contact exchange.
//  Reading: scan a Relay NFC tag/sticker → extracted username fed to onRead.
//  Writing: write your relaymsg.app/add/<username> URL to a writable NFC tag.
//
//  iPhone-to-iPhone NFC P2P is not supported on iOS; this targets external tags
//  (stickers, cards). readingAvailable returns false on iPad/simulator, so all
//  NFC UI is conditionally shown.
//

import CoreNFC
import Foundation

final class NFCContactManager: NSObject, NFCNDEFReaderSessionDelegate {
    static let shared = NFCContactManager()
    private override init() { super.init() }

    private var session: NFCNDEFReaderSession?
    private var mode: Mode = .read
    private var onRead: ((String) -> Void)?
    private var writePayload: NFCNDEFPayload?
    private var onWrite: ((Bool) -> Void)?

    private enum Mode { case read, write }

    static var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    // MARK: - Public API

    func startReading(onRead: @escaping (String) -> Void) {
        guard NFCNDEFReaderSession.readingAvailable else { return }
        mode = .read
        self.onRead = onRead
        session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        session?.alertMessage = "Hold your iPhone near the Relay NFC tag."
        session?.begin()
    }

    func startWriting(username: String, onWrite: @escaping (Bool) -> Void) {
        guard NFCNDEFReaderSession.readingAvailable else { onWrite(false); return }
        guard let url = URL(string: "https://relaymsg.app/add/\(username)"),
              let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url)
        else { onWrite(false); return }
        mode = .write
        writePayload = payload
        self.onWrite = onWrite
        session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        session?.alertMessage = "Hold your iPhone near a blank NFC tag or sticker."
        session?.begin()
    }

    // MARK: - NFCNDEFReaderSessionDelegate

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {}

    // Called in read mode (invalidateAfterFirstRead: true).
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        for message in messages {
            for record in message.records {
                if let url = record.wellKnownTypeURIPayload(),
                   let username = extractUsername(from: url) {
                    DispatchQueue.main.async { self.onRead?(username) }
                    return
                }
            }
        }
    }

    // Called in write mode (invalidateAfterFirstRead: false).
    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard mode == .write, let payload = writePayload, let tag = tags.first else { return }
        session.connect(to: tag) { [weak self] error in
            guard error == nil else {
                session.invalidate(errorMessage: "Could not connect to tag.")
                DispatchQueue.main.async { self?.onWrite?(false) }
                return
            }
            tag.queryNDEFStatus { status, _, error in
                guard error == nil, status == .readWrite else {
                    session.invalidate(errorMessage: "This tag is read-only and cannot be written.")
                    DispatchQueue.main.async { self?.onWrite?(false) }
                    return
                }
                tag.writeNDEF(NFCNDEFMessage(records: [payload])) { error in
                    if error != nil {
                        session.invalidate(errorMessage: "Write failed. Try holding the tag still.")
                        DispatchQueue.main.async { self?.onWrite?(false) }
                    } else {
                        session.alertMessage = "Done! Anyone can tap this tag to add you on Relay."
                        session.invalidate()
                        DispatchQueue.main.async { self?.onWrite?(true) }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func extractUsername(from url: URL) -> String? {
        if url.scheme == "relay", url.host == "add",
           let name = url.pathComponents.dropFirst().first, !name.isEmpty { return name }
        if url.host == "relaymsg.app", url.pathComponents.count >= 3,
           url.pathComponents[1] == "add" { return url.pathComponents[2] }
        return nil
    }
}
