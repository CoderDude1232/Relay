//
//  AppAttest.swift
//  Relay
//
//  Phone sign-in texts a code to a number before anyone is signed in, which
//  makes it the cheapest thing to abuse (SMS pumping). The relay only sends
//  one for a request signed by an App Attest key: a Secure Enclave key Apple
//  vouches for as belonging to this app on a real device. The key is attested
//  once per install; each code request is an assertion over the number.
//

import CryptoKit
import DeviceCheck
import Foundation
import RelayKit

enum AppAttest {
    private static let keyIdDefaultsKey = "relay.appAttestKeyId"

    struct UnavailableError: LocalizedError {
        var errorDescription: String? { "Signing in with a phone number needs Relay on an iPhone or iPad. Use email or a passkey here." }
    }

    /// Asks the relay to text a sign-in code to `phone`.
    static func requestPhoneCode(_ phone: String, api: RelayAPIClient) async throws {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            // The simulator: works only against a development relay that skips App Attest.
            do {
                try await api.startPhoneSignIn(phone: phone, attest: nil)
            } catch RelayAPIError.http(400, _) {
                throw UnavailableError()
            }
            return
        }
        for attempt in 0..<2 {
            let keyId = try await attestedKeyId(service: service, api: api)
            let challenge = try await api.appAttestChallenge()
            let clientData = Data(SHA256.hash(data: Data("relay-phone-start-v1|\(challenge)|\(phone)".utf8)))
            do {
                let assertion = try await service.generateAssertion(keyId, clientDataHash: clientData)
                try await api.startPhoneSignIn(
                    phone: phone, attest: (keyId: Data(base64Encoded: keyId) ?? Data(), assertion: assertion, challenge: challenge)
                )
                return
            } catch let error as DCError where error.code == .invalidKey && attempt == 0 {
                forgetKey()
            } catch RelayAPIError.http(412, _) where attempt == 0 {
                // The relay purged the key (unused for 90 days); attest a new one.
                forgetKey()
            }
        }
    }

    /// This install's attested key id (Apple's base64 form), made and attested
    /// on first use.
    private static func attestedKeyId(service: DCAppAttestService, api: RelayAPIClient) async throws -> String {
        if let saved = UserDefaults.standard.string(forKey: keyIdDefaultsKey) { return saved }
        let keyId = try await service.generateKey()
        let challenge = try await api.appAttestChallenge()
        let clientData = Data(SHA256.hash(data: Data("relay-app-attest-key-v1|\(challenge)".utf8)))
        let attestation = try await service.attestKey(keyId, clientDataHash: clientData)
        guard let keyIdData = Data(base64Encoded: keyId) else { throw RelayAPIError.malformedResponse }
        try await api.registerAppAttestKey(keyId: keyIdData, attestation: attestation, challenge: challenge)
        UserDefaults.standard.set(keyId, forKey: keyIdDefaultsKey)
        return keyId
    }

    private static func forgetKey() {
        UserDefaults.standard.removeObject(forKey: keyIdDefaultsKey)
    }
}
