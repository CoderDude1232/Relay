//
//  AppleReauthorization.swift
//  Relay
//
//  Sign in with Apple accounts must have their Apple token revoked on account
//  deletion (App Review 5.1.1(v)). Revocation needs a fresh authorization
//  code, so deletion requests one here and hands it to the relay, which
//  exchanges and revokes it immediately without storing anything.
//

import AuthenticationServices
import UIKit

enum AppleSignInRecord {
    private static let key = "relay.signedInWithApple"

    /// Whether this account was signed in with Apple on this device.
    static var used: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@MainActor
final class AppleReauthorization: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<String?, Never>?

    /// Asks Apple for a fresh authorization code; nil if the user cancels or
    /// it fails (deletion then proceeds without revocation).
    static func authorizationCode() async -> String? {
        let helper = AppleReauthorization()
        return await helper.run()
    }

    private func run() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = []
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?
            .authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in self.finish(code) }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController, didCompleteWithError error: Error
    ) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    private func finish(_ code: String?) {
        continuation?.resume(returning: code)
        continuation = nil
    }
}

/// Runs Sign in with Apple from our own button (so it can match the other
/// sign-in buttons) and returns the same result `SignInWithAppleButton` gives.
@MainActor
final class AppleSignInFlow: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<Result<ASAuthorization, Error>, Never>?

    static func run(scopes: [ASAuthorization.Scope]) async -> Result<ASAuthorization, Error> {
        let flow = AppleSignInFlow()
        return await withCheckedContinuation { continuation in
            flow.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = scopes
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = flow
            controller.presentationContextProvider = flow
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        nonisolated(unsafe) let authorization = authorization
        Task { @MainActor in self.finish(.success(authorization)) }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController, didCompleteWithError error: Error
    ) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
