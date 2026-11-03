//
//  WhatsAppExport.swift
//  Relay
//
//  Reads a WhatsApp "Export Chat" file: the .zip (chat text plus media) or the
//  bare .txt from "Without Media". Everything is parsed on the device; nothing
//  from the export is sent anywhere.
//

import Compression
import Foundation

nonisolated struct WhatsAppExport: Sendable {
    struct Message: Sendable, Equatable {
        /// Seconds since 1970, in this device's time zone.
        let date: Date
        let sender: String
        var text: String
        /// Name of a media file in the export.
        var attachment: String?
        /// The export says a photo or file was left out ("image omitted").
        var omittedMedia = false
    }

    /// The chat's name from the file name ("WhatsApp Chat - Morgan"), if any.
    let title: String?
    let messages: [Message]
    /// Everyone who sent a message, most active first.
    let senders: [String]
    /// Media files in the zip, by name.
    let media: [String: ZipArchive.Entry]
    let archive: ZipArchive?

    var isGroup: Bool { senders.count > 2 }

    enum ReadError: LocalizedError {
        case notAnExport, unreadableZip

        var errorDescription: String? {
            switch self {
            case .notAnExport: "This doesn't look like a WhatsApp chat export."
            case .unreadableZip: "This file couldn't be opened. Export the chat from WhatsApp again."
            }
        }
    }

    static func read(_ url: URL) throws -> WhatsAppExport {
        let title = titleFromFileName(url.deletingPathExtension().lastPathComponent)
        if url.pathExtension.lowercased() == "txt" {
            let text = try String(contentsOf: url, encoding: .utf8)
            return try make(text: text, title: title, archive: nil)
        }
        guard let archive = try? ZipArchive(url: url) else { throw ReadError.unreadableZip }
        // The chat is "_chat.txt" (iPhone) or "WhatsApp Chat with X.txt" (Android).
        let chatEntry = archive.entries.first { $0.name.lowercased().hasSuffix("_chat.txt") }
            ?? archive.entries.first { $0.name.lowercased().hasSuffix(".txt") && $0.name.contains("WhatsApp") }
        guard let chatEntry, let data = try? archive.extract(chatEntry),
              let text = String(data: data, encoding: .utf8)
        else { throw ReadError.notAnExport }
        let insideTitle = titleFromFileName((chatEntry.name as NSString).deletingPathExtension)
        return try make(text: text, title: title ?? insideTitle, archive: archive)
    }

    private static func make(text: String, title: String?, archive: ZipArchive?) throws -> WhatsAppExport {
        let messages = WhatsAppChatParser.parse(text)
        guard !messages.isEmpty else { throw ReadError.notAnExport }
        var counts: [String: Int] = [:]
        for m in messages { counts[m.sender, default: 0] += 1 }
        let senders = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var media: [String: ZipArchive.Entry] = [:]
        for entry in archive?.entries ?? [] {
            let name = (entry.name as NSString).lastPathComponent
            if !name.lowercased().hasSuffix(".txt") { media[name] = entry }
        }
        return WhatsAppExport(title: title, messages: messages, senders: senders, media: media, archive: archive)
    }

    /// "WhatsApp Chat - Morgan" (iPhone), "WhatsApp Chat with Morgan" (Android).
    static func titleFromFileName(_ name: String) -> String? {
        for prefix in ["WhatsApp Chat - ", "WhatsApp Chat with "] where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// True for files that are probably WhatsApp exports, judged by name only.
    static func looksLikeExport(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return (lower.hasSuffix(".zip") || lower.hasSuffix(".txt"))
            && (lower.hasPrefix("whatsapp chat") || lower == "_chat.txt")
    }
}

// MARK: - Chat text

/// Parses the chat text. Both phone formats are understood:
///   [15/03/2024, 9:41:05 pm] Morgan: hello          (iPhone)
///   15/03/2024, 21:41 - Morgan: hello               (Android)
/// with any date order, 12- or 24-hour times, and lines that continue the
/// message above them.
nonisolated enum WhatsAppChatParser {
    private struct Header {
        let a: Int, b: Int, c: Int
        let hour: Int, minute: Int, second: Int
        let meridiem: Character?   // "a" or "p"
        let rest: Substring
        let bracketed: Bool
    }

    static func parse(_ text: String, calendar: Calendar = .current, locale: Locale = .current) -> [WhatsAppExport.Message] {
        // Lines with a header, and the lines that follow each one.
        var blocks: [(Header, [Substring])] = []
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let header = header(line) {
                blocks.append((header, []))
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].1.append(line)
            }
        }
        guard !blocks.isEmpty else { return [] }

        let order = dateOrder(blocks.map(\.0), locale: locale)
        var messages: [WhatsAppExport.Message] = []
        for (header, continuation) in blocks {
            guard let date = date(header, order: order, calendar: calendar),
                  var message = message(header, date: date)
            else { continue }
            if !continuation.isEmpty {
                message.text += "\n" + continuation.joined(separator: "\n")
            }
            message.text = clean(message.text)
            if message.text.isEmpty, message.attachment == nil, !message.omittedMedia { continue }
            messages.append(message)
        }
        // The notice WhatsApp puts at the top of every chat.
        if let first = messages.first, first.text.contains("end-to-end encrypted"), first.attachment == nil {
            messages.removeFirst()
        }
        return messages
    }

    private static func header(_ raw: Substring) -> Header? {
        var line = raw.drop { $0 == "\u{200E}" || $0 == "\u{200F}" || $0 == " " }
        let bracketed = line.first == "["
        if bracketed { line = line.dropFirst() }
        var s = Scanner(line)
        guard let a = s.number(), s.skip(any: "/.-"),
              let b = s.number(), s.skip(any: "/.-"),
              let c = s.number()
        else { return nil }
        s.skip(any: ","); s.skipSpaces()
        guard let hour = s.number(), s.skip(any: ":."), let minute = s.number() else { return nil }
        var second = 0
        if s.peek == ":" || s.peek == "." {
            s.advance()
            guard let sec = s.number() else { return nil }
            second = sec
        }
        s.skipSpaces()
        let meridiem = s.meridiem()
        s.skipSpaces()
        if bracketed {
            guard s.skip(any: "]") else { return nil }
            s.skipSpaces()
        } else {
            guard s.skip(any: "-") else { return nil }
            s.skipSpaces()
        }
        guard hour < 24, minute < 60, second < 60 else { return nil }
        return Header(a: a, b: b, c: c, hour: hour, minute: minute, second: second,
                      meridiem: meridiem, rest: s.remainder, bracketed: bracketed)
    }

    private enum DateOrder { case dmy, mdy, ymd }

    /// The same order holds for the whole file, so any day above 12 settles it.
    private static func dateOrder(_ headers: [Header], locale: Locale) -> DateOrder {
        if headers.contains(where: { $0.a > 31 }) { return .ymd }
        if headers.contains(where: { $0.a > 12 }) { return .dmy }
        if headers.contains(where: { $0.b > 12 }) { return .mdy }
        let format = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: locale) ?? "d/M/y"
        let d = format.firstIndex(of: "d"), m = format.firstIndex(of: "M")
        if let d, let m, m < d { return .mdy }
        return .dmy
    }

    private static func date(_ h: Header, order: DateOrder, calendar: Calendar) -> Date? {
        var parts = DateComponents()
        switch order {
        case .dmy: (parts.day, parts.month, parts.year) = (h.a, h.b, h.c)
        case .mdy: (parts.month, parts.day, parts.year) = (h.a, h.b, h.c)
        case .ymd: (parts.year, parts.month, parts.day) = (h.a, h.b, h.c)
        }
        if let year = parts.year, year < 100 { parts.year = 2000 + year }
        var hour = h.hour
        if let meridiem = h.meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "p", hour != 12 { hour += 12 }
            if meridiem == "a", hour == 12 { hour = 0 }
        }
        parts.hour = hour
        parts.minute = h.minute
        parts.second = h.second
        guard let month = parts.month, (1...12).contains(month),
              let day = parts.day, (1...31).contains(day)
        else { return nil }
        return calendar.date(from: parts)
    }

    private static func message(_ h: Header, date: Date) -> WhatsAppExport.Message? {
        // "Name: text". Without a name it's a notice ("Morgan added you").
        guard let colon = h.rest.range(of: ": ") else { return nil }
        let sender = String(h.rest[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        var body = String(h.rest[colon.upperBound...])
        guard !sender.isEmpty, sender.count <= 80 else { return nil }
        let isNotice = body.hasPrefix("\u{200E}")
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F} "))

        var message = WhatsAppExport.Message(date: date, sender: sender, text: body)
        // iPhone: "<attached: 00000012-PHOTO-2024-03-15-21-41-05.jpg>"
        if body.hasPrefix("<attached: "), let close = body.firstIndex(of: ">") {
            message.attachment = String(body[body.index(body.startIndex, offsetBy: 11)..<close])
            message.text = String(body[body.index(after: close)...])
            return message
        }
        // Android: "IMG-20240315-WA0003.jpg (file attached)\ncaption"
        if let range = body.range(of: " (file attached)") {
            message.attachment = String(body[..<range.lowerBound])
            message.text = String(body[range.upperBound...])
            return message
        }
        let lower = body.lowercased()
        if lower == "<media omitted>" || (isNotice && lower.hasSuffix(" omitted")) {
            message.omittedMedia = true
            message.text = ""
            return message
        }
        return message
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "<This message was edited>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tiny cursor over a line: avoids regexes so every phone locale's
    /// punctuation can be accepted.
    private struct Scanner {
        private var s: Substring
        init(_ s: Substring) { self.s = s }
        var peek: Character? { s.first }
        var remainder: Substring { s }
        mutating func advance() { s = s.dropFirst() }
        mutating func number() -> Int? {
            let digits = s.prefix { $0.isASCII && $0.isNumber }
            guard (1...4).contains(digits.count) else { return nil }
            s = s.dropFirst(digits.count)
            return Int(digits)
        }
        @discardableResult mutating func skip(any chars: String) -> Bool {
            guard let c = s.first, chars.contains(c) else { return false }
            s = s.dropFirst()
            return true
        }
        mutating func skipSpaces() { s = s.drop { $0 == " " } }
        /// "am", "PM", "a.m.", "a. m." → "a" or "p".
        mutating func meridiem() -> Character? {
            guard let first = s.first.map({ Character($0.lowercased()) }), first == "a" || first == "p" else { return nil }
            var rest = s.dropFirst()
            if rest.first == "." { rest = rest.dropFirst() }
            rest = rest.drop { $0 == " " }
            guard rest.first?.lowercased() == "m" else { return nil }
            rest = rest.dropFirst()
            if rest.first == "." { rest = rest.dropFirst() }
            s = rest
            return first
        }
    }
}

// MARK: - Zip

/// Just enough of the zip format to read an export: the central directory,
/// stored and deflated entries, and zip64 sizes. The file is memory-mapped, so
/// a large export isn't read into memory up front.
nonisolated final class ZipArchive: @unchecked Sendable {
    struct Entry: Sendable {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    enum ZipError: Error { case malformed, unsupported, tooLarge }

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        entries = try Self.readDirectory(data)
    }

    /// The entry's contents. Refuses anything over `limit` bytes uncompressed.
    func extract(_ entry: Entry, limit: UInt64 = 200 * 1024 * 1024) throws -> Data {
        guard entry.size <= limit else { throw ZipError.tooLarge }
        let local = Int(entry.localHeaderOffset)
        guard local + 30 <= data.count, data.u32(local) == 0x0403_4B50 else { throw ZipError.malformed }
        let start = local + 30 + Int(data.u16(local + 26)) + Int(data.u16(local + 28))
        let end = start + Int(entry.compressedSize)
        guard start <= end, end <= data.count else { throw ZipError.malformed }
        let compressed = data[data.startIndex + start ..< data.startIndex + end]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            if entry.size == 0 { return Data() }
            var output = Data(count: Int(entry.size))
            let written = output.withUnsafeMutableBytes { out in
                compressed.withUnsafeBytes { input in
                    // COMPRESSION_ZLIB is raw deflate, which is what zip stores.
                    compression_decode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, Int(entry.size),
                        input.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == Int(entry.size) else { throw ZipError.malformed }
            return output
        default:
            throw ZipError.unsupported
        }
    }

    private static func readDirectory(_ data: Data) throws -> [Entry] {
        // The end-of-central-directory record is in the last 64 KiB + 22 bytes.
        let count = data.count
        guard count >= 22 else { throw ZipError.malformed }
        var eocd = -1
        var i = count - 22
        let floor = max(0, count - 22 - 65_535)
        while i >= floor {
            if data.u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.malformed }
        var total = UInt64(data.u16(eocd + 10))
        var dirOffset = UInt64(data.u32(eocd + 16))
        // Zip64: the locator sits just before the record.
        if (total == 0xFFFF || dirOffset == 0xFFFF_FFFF), eocd >= 20, data.u32(eocd - 20) == 0x0706_4B50 {
            let record = Int(data.u64(eocd - 12))
            guard record + 56 <= count, data.u32(record) == 0x0606_4B50 else { throw ZipError.malformed }
            total = data.u64(record + 32)
            dirOffset = data.u64(record + 48)
        }
        var entries: [Entry] = []
        var p = Int(dirOffset)
        for _ in 0..<min(total, 100_000) {
            guard p + 46 <= count, data.u32(p) == 0x0201_4B50 else { throw ZipError.malformed }
            let flags = data.u16(p + 8)
            let method = data.u16(p + 10)
            var compressed = UInt64(data.u32(p + 20))
            var size = UInt64(data.u32(p + 24))
            let nameLength = Int(data.u16(p + 28))
            let extraLength = Int(data.u16(p + 30))
            let commentLength = Int(data.u16(p + 32))
            var offset = UInt64(data.u32(p + 42))
            guard p + 46 + nameLength + extraLength <= count else { throw ZipError.malformed }
            let nameData = data[data.startIndex + p + 46 ..< data.startIndex + p + 46 + nameLength]
            // Bit 11: UTF-8 names. Older tools wrote CP437; Latin-1 is close enough.
            let name = String(data: nameData, encoding: flags & 0x800 != 0 ? .utf8 : .isoLatin1)
                ?? String(decoding: nameData, as: UTF8.self)
            // Zip64 extra field: only the fields that overflowed are present, in order.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = data.u16(e), length = Int(data.u16(e + 2))
                if id == 0x0001 {
                    var f = e + 4
                    if size == 0xFFFF_FFFF, f + 8 <= extraEnd { size = data.u64(f); f += 8 }
                    if compressed == 0xFFFF_FFFF, f + 8 <= extraEnd { compressed = data.u64(f); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= extraEnd { offset = data.u64(f) }
                }
                e += 4 + length
            }
            if !name.hasSuffix("/"), !name.hasPrefix("__MACOSX/") {
                entries.append(Entry(name: name, method: method, compressedSize: compressed,
                                     size: size, localHeaderOffset: offset))
            }
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}

private extension Data {
    nonisolated func u16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    nonisolated func u32(_ at: Int) -> UInt32 {
        UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
    }
    nonisolated func u64(_ at: Int) -> UInt64 {
        UInt64(u32(at)) | UInt64(u32(at + 4)) << 32
    }
}
