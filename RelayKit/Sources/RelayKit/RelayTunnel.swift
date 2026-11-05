//
//  RelayTunnel.swift
//  RelayKit
//
//  The encrypted tunnel to relayd (docs/TUNNEL.md). Every request to the relay
//  goes as POST /v1/t: an Oblivious HTTP message (RFC 9458) holding a
//  known-length Binary HTTP request (RFC 9292), encrypted to relayd's tunnel
//  key with X-Wing (ML-KEM-768 + X25519), HKDF-SHA256 and AES-256-GCM and
//  padded. Cloudflare, which terminates TLS in front of relayd, then sees
//  sizes and timing but no paths, signatures, account ids or mailboxes. The
//  WebSocket opens the same way and then encrypts each frame (Frames).
//

import CryptoKit
import Foundation

public enum RelayTunnel {
    static let keyId: UInt8 = 1
    /// relayd's tunnel key (public half); its private half never leaves the relay.
    static let publicKey: XWingMLKEM768X25519.PublicKey = {
        let base64 = [
        "9DgUG4mlVWKHe+hoq1k+indUHFSJLuZ4SaGZ1koBnAARH3GRELl2YZsH8luVvOw/Lxu5w4BFOyBow/zBtpkSdnB4dXaN21k7",
        "14ypToIhhwNuKVQ+NIQrtKZTXFKbEAsagfw8bLiQq5U1p8o80wIoL9djrhNAR/xlfeN9y6MnsSQW+HIQhmi7oaQiNSLHm6gk",
        "9OXHx1aUw+F+IvNea2CjtmBYOeiYKbJDPIw8ZxggVBeE+jYRowrMH0mF8jXKCXF41zhbY3ON1Tp2c/Z6SocRu9qf1UkiSfkU",
        "iJo0ehmo2WNyZPmEKekGQ6uEh3YK2HqStDWA/yNh4bcQzdEhfEq1cxgWtkwWkqea/jGbboZZpzJ41NEukTAhhOhkdTY58lg9",
        "dHo4blCbmPce13snIzDGoahaoJUGysObfkHM/VEkgKIm4foOJVIbnnxEa9MA0+g+MCu4QkQ7yvi2HIWOoaQDmnRny9xdodk6",
        "CsxBy0RD5ttrirsRQQeniQxII6IxWbFAxadBO4sUDWKbIEmgg2S80CSIi/u+Bwe6GPY1AtJodnSJmbjGUIAn7siV0ZWhogZU",
        "99O1QuhMuZjF9HFIXvgMlNcElGKNIKl0gRhAQ5EiyNaHgKV+MKkTANmvXtyWx5AmFKZHv6OazEjFtTA6KQis92x67fkwpviR",
        "+rtdCcN/cVhKp8gdPwHEa0Kw3FsuRYqhZYlEZji2vRqu6CxWYMF9BJdckCl92BRhadc4cCuL1gmqHUggeAAshjC0BiADaAZz",
        "V1VxHQOWqVC+rvDCHQRgDIFUwglXfgFXjuRNmtR6G5mO6EJrEoA59wpRaXoDCZSQk3Mx+GmHq+kBSiMMABKWbVWUakZUAlwK",
        "R8Yda6sOAEI5HEm3xjSvP+rDMXYbw+Iu3gXIuUJ/w7Uxn8GlLlUCsWUmkBdTJ7i63Isv4eCCvOi7diAjjhVTSaVOTtBJJRC2",
        "rLjBHIIYPZnElROQfqltFNyq5lcgRGTCumiAGRq+N+QlxbtTyrtfGASCV0CkBdx6MlVsSLCdXrvNHyGoViWbUFx1aoufWIVE",
        "3ee441GtOmjJfXtO09gTtkbLJEx0AqjKNooeYdiwu3ey8aMY97Zv7jhaB5u1etNBPBEmbWdm11pquImAujCCbkde/+iMfVRU",
        "Exx0OnYapNYPz+ZrrERHBWW2YeGa5VFCVBA8MbnHDdVsjzExKphW1qNTBjpkNzaQKTJsNeupoXGi+VcrZRlwRJxpJLAypCQB",
        "g6y17QJ5aoWmw2d3/qGgTttyscKv/+FNGFKhGtgtGtJafyGh7Lg5+Qsp4vwS5qLCvsZFqiJfb4tHC5RIlIOAiektmbRHWqON",
        "5noKwnrAviucO1oJz8EMVKcyKdeUGqNp1GM1FaBtWOTGDxNXUUeWuhc+bVoWwiMnNlm2PZEMy9pRNDy+U0x22IBHdARckRqW",
        "QSBZ0kKqiiVM9yxyjCnHCfIOPZqmYUnAb6AGgDY+2fhPkzVEzDAeENq27PRXwwoAcwCVBuhyN8FBcVGsm0dIFDBuo/V6FCEi",
        "ZF/rNcaUdsOZhtSSCaaYQBpIpIRgVfbFSQhryN+haL0HYuGjm5ldnRQBJR6E5bjCVHhKOfF3GVK0s7bTCoMQGg==",        ].joined()
        // A bad built-in key is a build defect, not a runtime condition.
        return try! XWingMLKEM768X25519.PublicKey(rawRepresentation: Data(base64Encoded: base64)!)
    }()

    /// Largest body sent through the tunnel; bigger attachments go direct.
    public static let maxBody = 8 << 20

    static let ciphersuite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
    private static let header = Data([keyId, 0x64, 0x7a, 0x00, 0x01, 0x00, 0x02])
    private static let requestLabel = Data("message/bhttp request".utf8)
    private static let responseLabel = Data("message/bhttp response".utf8)

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data

        /// relayd couldn't carry it (too large); send it directly instead.
        var tooLarge: Bool { status == 413 && headers["x-relay-tunnel"] == "too-large" }
    }

    /// A sealed request, kept to open its response.
    struct Pending {
        fileprivate let sender: HPKE.Sender
        fileprivate let enc: Data

        /// RFC 9458 section 4.4.
        func open(_ message: Data) throws -> Response {
            guard message.count > 32 else { throw RelayTunnelError.malformed }
            let secret = try sender.exportSecret(context: RelayTunnel.responseLabel, outputByteCount: 32)
            let salt = enc + message.prefix(32)
            let prk = HKDF<SHA256>.extract(inputKeyMaterial: secret, salt: salt)
            let key = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("key".utf8), outputByteCount: 32)
            let nonce = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("nonce".utf8), outputByteCount: 12)
            let sealed = message.dropFirst(32)
            guard sealed.count >= 16 else { throw RelayTunnelError.malformed }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }),
                                            ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try BinaryHTTP.decodeResponse(AES.GCM.open(box, using: key))
        }

        /// The WebSocket's frame ciphers, once its opening request is accepted.
        func frames() throws -> Frames {
            Frames(send: try sender.exportSecret(context: Data("relay tunnel ws c2s".utf8), outputByteCount: 32),
                   receive: try sender.exportSecret(context: Data("relay tunnel ws s2c".utf8), outputByteCount: 32))
        }
    }

    /// Seals `request` (already signed, if it's authenticated). Only the
    /// headers relayd accepts inside the tunnel are carried.
    static func seal(_ request: URLRequest) throws -> (message: Data, pending: Pending) {
        guard let url = request.url else { throw RelayTunnelError.malformed }
        var headers: [(String, String)] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if carriedHeaders.contains(lower) { headers.append((lower, value)) }
        }
        let inner = BinaryHTTP.encodeRequest(method: request.httpMethod ?? "GET", authority: url.host() ?? "",
                                             path: RelaySignature.requestURI(url), headers: headers,
                                             body: request.httpBody ?? Data())
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: ciphersuite, info: requestLabel + [0] + header)
        let ciphertext = try sender.seal(pad(inner))
        return (header + sender.encapsulatedKey + ciphertext, Pending(sender: sender, enc: sender.encapsulatedKey))
    }

    private static let carriedHeaders: Set<String> = [
        "authorization", "content-type", "relay-access-key",
        "x-relay-timestamp", "x-relay-nonce", "x-relay-content-sha256",
    ]

    /// Powers of two from 256 bytes to 64 KiB, then multiples of 64 KiB.
    static func paddedLength(_ n: Int) -> Int {
        var bucket = 256
        while bucket <= 64 << 10 {
            if n <= bucket { return bucket }
            bucket <<= 1
        }
        return (n + (64 << 10) - 1) / (64 << 10) * (64 << 10)
    }

    static func pad(_ data: Data) -> Data {
        data + Data(count: paddedLength(data.count) - data.count)
    }

    /// Encrypts and decrypts WebSocket frames after the opening exchange: one
    /// key per direction, a 96-bit big-endian counter nonce from zero, and a
    /// 4-byte length before the padded frame.
    struct Frames {
        private let sendKey: SymmetricKey
        private let receiveKey: SymmetricKey
        private var sent: UInt64 = 0
        private var received: UInt64 = 0

        init(send: SymmetricKey, receive: SymmetricKey) {
            sendKey = send
            receiveKey = receive
        }

        private static func nonce(_ n: UInt64) -> AES.GCM.Nonce {
            var bytes = Data(count: 4)
            withUnsafeBytes(of: n.bigEndian) { bytes.append(contentsOf: $0) }
            return try! AES.GCM.Nonce(data: bytes)
        }

        mutating func seal(_ frame: Data) throws -> Data {
            var length = UInt32(frame.count).bigEndian
            let plain = RelayTunnel.pad(Data(bytes: &length, count: 4) + frame)
            let box = try AES.GCM.seal(plain, using: sendKey, nonce: Self.nonce(sent))
            sent += 1
            return box.ciphertext + box.tag
        }

        /// Throws on any frame that doesn't open; the connection must close.
        mutating func open(_ message: Data) throws -> Data {
            guard message.count >= 16 else { throw RelayTunnelError.malformed }
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(received), ciphertext: message.dropLast(16),
                                            tag: message.suffix(16))
            let plain = try AES.GCM.open(box, using: receiveKey)
            received += 1
            guard plain.count >= 4 else { throw RelayTunnelError.malformed }
            let length = plain.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= plain.count - 4 else { throw RelayTunnelError.malformed }
            return Data(plain.dropFirst(4).prefix(length))
        }
    }
}

enum RelayTunnelError: Error {
    case malformed
    /// The relay refused the tunnel itself (not the request inside it).
    case refused(status: Int)
}

/// Known-length Binary HTTP (RFC 9292): what the tunnel needs of it.
enum BinaryHTTP {
    static func appendVarint(_ v: UInt64, to data: inout Data) {
        switch v {
        case ..<(1 << 6): data.append(UInt8(v))
        case ..<(1 << 14): withUnsafeBytes(of: (UInt16(v) | 0x4000).bigEndian) { data.append(contentsOf: $0) }
        case ..<(1 << 30): withUnsafeBytes(of: (UInt32(v) | 0x8000_0000).bigEndian) { data.append(contentsOf: $0) }
        default: withUnsafeBytes(of: (v | 0xc000_0000_0000_0000).bigEndian) { data.append(contentsOf: $0) }
        }
    }

    static func appendField(_ field: Data, to data: inout Data) {
        appendVarint(UInt64(field.count), to: &data)
        data.append(field)
    }

    static func encodeRequest(method: String, authority: String, path: String,
                              headers: [(String, String)], body: Data) -> Data {
        var data = Data([0]) // known-length request
        for part in [method, "https", authority, path] { appendField(Data(part.utf8), to: &data) }
        var section = Data()
        for (name, value) in headers {
            appendField(Data(name.utf8), to: &section)
            appendField(Data(value.utf8), to: &section)
        }
        appendField(section, to: &data)
        appendField(body, to: &data)
        data.append(0) // no trailers
        return data
    }

    private struct Reader {
        var data: Data.SubSequence

        mutating func varint() throws -> UInt64 {
            guard let first = data.first else { throw RelayTunnelError.malformed }
            let length = 1 << (first >> 6)
            guard data.count >= length else { throw RelayTunnelError.malformed }
            var v = UInt64(first & 0x3f)
            for byte in data.dropFirst().prefix(length - 1) { v = v << 8 | UInt64(byte) }
            data = data.dropFirst(length)
            return v
        }

        mutating func field() throws -> Data.SubSequence {
            let n = try varint()
            guard n <= UInt64(data.count) else { throw RelayTunnelError.malformed }
            let v = data.prefix(Int(n))
            data = data.dropFirst(Int(n))
            return v
        }
    }

    static func decodeResponse(_ bytes: Data) throws -> RelayTunnel.Response {
        var r = Reader(data: bytes[...])
        guard try r.varint() == 1 else { throw RelayTunnelError.malformed }
        let status = try r.varint()
        guard (200...599).contains(status) else { throw RelayTunnelError.malformed }
        var section = Reader(data: try r.field())
        var headers: [String: String] = [:]
        while !section.data.isEmpty {
            let name = String(decoding: try section.field(), as: UTF8.self).lowercased()
            headers[name] = String(decoding: try section.field(), as: UTF8.self)
        }
        let body = Data(try r.field())
        return RelayTunnel.Response(status: Int(status), headers: headers, body: body)
    }
}
