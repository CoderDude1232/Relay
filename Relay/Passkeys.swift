//
//  Passkeys.swift
//  Relay
//
//  Passkey creation and sign-in for relaymsg.app via AuthenticationServices.
//  Every request also asks for the passkey's PRF output, which unlocks the
//  chat list kept with the account (AccountStorage).
//

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum PasskeyError: LocalizedError {
    case canceled
    case unsupported
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .canceled: "Cancelled."
        case .unsupported: "Passkeys aren't available on this device."
        case .failed(let message): message
        }
    }
}

struct PasskeyRegistrationResult {
    let credentialId: Data
    let clientDataJSON: Data
    let attestationObject: Data
    /// Nil if the passkey provider doesn't support PRF.
    let prfOutput: Data?
}

struct PasskeyAssertionResult {
    let credentialId: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data
    let userHandle: Data
    let prfOutput: Data?
}

@MainActor
final class PasskeyAuthenticator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let relyingParty = "relaymsg.app"

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    private var provider: ASAuthorizationPlatformPublicKeyCredentialProvider {
        ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
    }

    func register(challenge: Data, userId: Data, userName: String, excluding: [Data]) async throws -> PasskeyRegistrationResult {
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: userId)
        request.userVerificationPreference = .required
        request.excludedCredentials = excluding.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        request.prf = .inputValues(.init(saltInput1: AccountStorageCrypto.prfSalt))
        let authorization = try await perform([request], autoFill: false)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject
        else { throw PasskeyError.failed("The passkey couldn't be created.") }
        return PasskeyRegistrationResult(
            credentialId: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON,
            attestationObject: attestation,
            prfOutput: credential.prf?.first.map(Self.data)
        )
    }

    /// Signs in with any passkey for relaymsg.app. With `autoFill`, the request
    /// waits for the user to pick a passkey from the keyboard's suggestions.
    func assert(challenge: Data, autoFill: Bool = false, credentialId: Data? = nil) async throws -> PasskeyAssertionResult {
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        if let credentialId {
            request.allowedCredentials = [ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialId)]
        }
        request.prf = .inputValues(.init(saltInput1: AccountStorageCrypto.prfSalt))
        let authorization = try await perform([request], autoFill: autoFill)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
              let userHandle = credential.userID
        else { throw PasskeyError.failed("Passkey sign-in failed.") }
        return PasskeyAssertionResult(
            credentialId: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON,
            authenticatorData: credential.rawAuthenticatorData,
            signature: credential.signature,
            userHandle: userHandle,
            prfOutput: credential.prf.map { Self.data($0.first) }
        )
    }

    /// Stops a pending keyboard-suggestion request.
    func cancel() {
        controller?.cancel()
        controller = nil
    }

    private static func data(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func perform(_ requests: [ASAuthorizationRequest], autoFill: Bool) async throws -> ASAuthorization {
        cancel()
        let controller = ASAuthorizationController(authorizationRequests: requests)
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if autoFill {
                controller.performAutoFillAssistedRequests()
            } else {
                controller.performRequests()
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        nonisolated(unsafe) let authorization = authorization
        Task { @MainActor in
            self.continuation?.resume(returning: authorization)
            self.continuation = nil
            self.controller = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let code = (error as? ASAuthorizationError)?.code
        let message = error.localizedDescription
        Task { @MainActor in
            let mapped: Error = switch code {
            case .canceled?: PasskeyError.canceled
            case .notHandled?, .notInteractive?: PasskeyError.unsupported
            default: PasskeyError.failed(message)
            }
            self.continuation?.resume(throwing: mapped)
            self.continuation = nil
            self.controller = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
