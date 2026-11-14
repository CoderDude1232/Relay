//
//  PinLockTests.swift
//  SecureStorageTests
//
//  The PIN lock's crypto. The relay is played by a local scalar; the vector
//  test pins the maths to server/internal/pinguard (Go, gtank/ristretto255).
//  The Keychain items need a hosted app and are checked on device.
//

import Clibsodium
import CryptoKit
import Foundation
import Testing

@testable import SecureStorage

private func hex(_ s: String) -> Data {
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        data.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return data
}

/// The relay's evaluate: k·B.
private func relayEvaluate(_ scalar: Data, _ blinded: Data) -> Data {
    var out = [UInt8](repeating: 0, count: 32)
    let rc = crypto_scalarmult_ristretto255(&out, [UInt8](scalar), [UInt8](blinded))
    precondition(rc == 0)
    return Data(out)
}

private func randomScalar() -> Data {
    var k = [UInt8](repeating: 0, count: 32)
    crypto_core_ristretto255_scalar_random(&k)
    return Data(k)
}

/// One full unlock as the app will do it, against a local stand-in relay.
private func oprf(pin: String, salt: Data, relayKey: Data) throws -> Data {
    let blinded = try PinLockCrypto.blind(stretched: PinLockCrypto.stretch(pin: pin, salt: salt))
    return try PinLockCrypto.unblind(blinded, evaluated: relayEvaluate(relayKey, blinded.element))
}

@Suite struct PinLockTests {
    /// Same answer as the Go relay for the same point and key.
    @Test func matchesServerVector() throws {
        let scalar = hex("e9962f0cd6ca51f41cc498a6b390150eccafd28a5586c9eccee5ea79fe841a02")
        let evaluated = hex("50fe4ffdd495bb67aea6adb00f058456eeb71d5cff151ca0d841031394eeae6d")
        // blind() hashes domain ‖ input, which is how the Go vector made its point.
        let blinded = try PinLockCrypto.blind(stretched: Data("vector".utf8))
        let out = try PinLockCrypto.unblind(blinded, evaluated: relayEvaluate(scalar, blinded.element))
        #expect(out == evaluated)
    }

    @Test func samePinSameKeyDifferentPinsDont() throws {
        let salt = PinLockCrypto.newSalt()
        let relayKey = randomScalar()
        let a = try oprf(pin: "123456", salt: salt, relayKey: relayKey)
        let b = try oprf(pin: "123456", salt: salt, relayKey: relayKey)
        #expect(a == b)
        #expect(try oprf(pin: "123457", salt: salt, relayKey: relayKey) != a)
        #expect(try oprf(pin: "123456", salt: PinLockCrypto.newSalt(), relayKey: relayKey) != a)
        #expect(try oprf(pin: "123456", salt: salt, relayKey: randomScalar()) != a)
    }

    @Test func blindingHidesThePin() throws {
        let stretched = try PinLockCrypto.stretch(pin: "123456", salt: PinLockCrypto.newSalt())
        let one = try PinLockCrypto.blind(stretched: stretched)
        let two = try PinLockCrypto.blind(stretched: stretched)
        #expect(one.element != two.element)
    }

    @Test func sealedKeyOpensOnlyWithTheRightPinAndDevice() throws {
        let salt = PinLockCrypto.newSalt()
        let relayKey = randomScalar()
        let deviceSecret = DatabaseKey.random().bytes
        let master = DatabaseKey.random().bytes

        let enrolled = PinLockCrypto.keys(oprfOutput: try oprf(pin: "482910", salt: salt, relayKey: relayKey),
                                          deviceSecret: deviceSecret, salt: salt)
        let sealed = try PinLockCrypto.seal(master, with: enrolled.kek)
        #expect(sealed.count == 12 + 32 + 16)

        let right = PinLockCrypto.keys(oprfOutput: try oprf(pin: "482910", salt: salt, relayKey: relayKey),
                                       deviceSecret: deviceSecret, salt: salt)
        #expect(try PinLockCrypto.open(sealed, with: right.kek) == master)
        #expect(PinLockCrypto.equal(right.verifier, enrolled.verifier))
        #expect(right.verifier.count == 32)

        let wrongPin = PinLockCrypto.keys(oprfOutput: try oprf(pin: "482911", salt: salt, relayKey: relayKey),
                                          deviceSecret: deviceSecret, salt: salt)
        #expect(throws: PinLockError.sealedKeyDidNotOpen) { try PinLockCrypto.open(sealed, with: wrongPin.kek) }
        #expect(!PinLockCrypto.equal(wrongPin.verifier, enrolled.verifier))

        // The relay's answer alone, without this phone's secret, opens nothing
        // and can't reproduce the verifier.
        let otherDevice = PinLockCrypto.keys(oprfOutput: try oprf(pin: "482910", salt: salt, relayKey: relayKey),
                                             deviceSecret: DatabaseKey.random().bytes, salt: salt)
        #expect(throws: PinLockError.sealedKeyDidNotOpen) { try PinLockCrypto.open(sealed, with: otherDevice.kek) }
        #expect(!PinLockCrypto.equal(otherDevice.verifier, enrolled.verifier))

        // A new relay key (after 10 wrong PINs, or re-enrolment) can't open it either.
        let newRelayKey = PinLockCrypto.keys(oprfOutput: try oprf(pin: "482910", salt: salt, relayKey: randomScalar()),
                                             deviceSecret: deviceSecret, salt: salt)
        #expect(throws: PinLockError.sealedKeyDidNotOpen) { try PinLockCrypto.open(sealed, with: newRelayKey.kek) }

        // KEK and verifier are independent outputs.
        #expect(enrolled.kek.withUnsafeBytes { Data($0) } != enrolled.verifier)
    }

    @Test func tamperedSealedKeyIsRefused() throws {
        let kek = SymmetricKey(size: .bits256)
        var sealed = try PinLockCrypto.seal(DatabaseKey.random().bytes, with: kek)
        sealed[sealed.startIndex + 20] ^= 0x01
        #expect(throws: PinLockError.sealedKeyDidNotOpen) { try PinLockCrypto.open(sealed, with: kek) }
    }

    @Test func badRelayAnswersAreRefused() throws {
        let blinded = try PinLockCrypto.blind(stretched: Data(repeating: 7, count: 32))
        for bad in [Data(), Data(count: 31), Data(count: 32), Data(repeating: 0xff, count: 32)] {
            #expect(throws: PinLockError.self) { try PinLockCrypto.unblind(blinded, evaluated: bad) }
        }
    }

    @Test func stretchNeedsAProperSalt() throws {
        #expect(throws: PinLockError.self) { try PinLockCrypto.stretch(pin: "1234", salt: Data(count: 8)) }
        let salt = PinLockCrypto.newSalt()
        #expect(salt.count == 16)
        #expect(try PinLockCrypto.stretch(pin: "1234", salt: salt) == PinLockCrypto.stretch(pin: "1234", salt: salt))
        #expect(try PinLockCrypto.stretch(pin: "1234", salt: salt) != PinLockCrypto.stretch(pin: "4321", salt: salt))
    }

    @Test func constantTimeEqual() {
        #expect(PinLockCrypto.equal(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!PinLockCrypto.equal(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!PinLockCrypto.equal(Data([1, 2, 3]), Data([1, 2])))
    }
}
