//
//  PinLockView.swift
//  Relay
//
//  The Relay PIN screen (PinLockManager), in its own window above the app and
//  its sheets, like the Face ID lock (PrivacyShield). The distress PIN is
//  typed here too and looks the same as unlocking.
//

import SwiftUI
import UIKit

@MainActor
final class PinLockShield {
    static let shared = PinLockShield()
    private var window: UIWindow?

    func update(locked: Bool, model: AppModel) {
        guard locked else {
            window?.isHidden = true
            window = nil
            return
        }
        // Don't leave a half-typed message showing in the keyboard.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard window == nil else { window?.isHidden = false; return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        else { return }
        let window = UIWindow(windowScene: scene)
        // Above the app-switcher blur and the Face ID lock.
        window.windowLevel = .alert + 2
        let host = UIHostingController(rootView: PinLockView().environment(model))
        host.view.backgroundColor = .black
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

struct PinLockView: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var message: String?
    @State private var working = false
    @State private var shake = 0
    @State private var waitUntil: Date?

    private static let maxDigits = 8
    private static let minDigits = 4

    var body: some View {
        ZStack {
            BackgroundGradient()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                Image("RelayLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120)
                    .accessibilityLabel("Relay")
                Text("Enter your Relay PIN")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 28)
                dots
                    .padding(.top, 22)
                    .modifier(Shake(animatableData: CGFloat(shake)))
                Group {
                    if working {
                        ProgressView().tint(.white)
                    } else if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                    } else {
                        Text(" ").font(.footnote)
                    }
                }
                .frame(minHeight: 40)
                .padding(.horizontal, 32)
                .padding(.top, 14)
                Spacer(minLength: 20)
                keypad
                    .padding(.bottom, 36)
            }
            .frame(maxWidth: 420)
        }
        .environment(\.colorScheme, .dark)
        .disabled(working)
    }

    private var dots: some View {
        HStack(spacing: 16) {
            ForEach(0..<max(Self.minDigits, pin.count), id: \.self) { i in
                Circle()
                    .fill(i < pin.count ? Color.white : Color.clear)
                    .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5) }
                    .frame(width: 13, height: 13)
            }
        }
        .animation(.spring(duration: 0.2), value: pin.count)
        .accessibilityElement()
        .accessibilityLabel("\(pin.count) digits entered")
    }

    private var keypad: some View {
        VStack(spacing: 18) {
            ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                HStack(spacing: 26) { ForEach(row, id: \.self) { digitKey($0) } }
            }
            HStack(spacing: 26) {
                Button { pin.removeLast() } label: {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                }
                .disabled(pin.isEmpty)
                .opacity(pin.isEmpty ? 0.3 : 1)
                .accessibilityLabel("Delete")
                digitKey("0")
                Button { submit() } label: {
                    Image(systemName: "arrow.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(canSubmit ? Color.black : .white.opacity(0.4))
                        .frame(width: 76, height: 76)
                        .background(canSubmit ? Color.white : Color.white.opacity(0.1), in: .circle)
                }
                .disabled(!canSubmit)
                .accessibilityLabel("Unlock")
            }
        }
    }

    private var canSubmit: Bool { pin.count >= Self.minDigits && !working }

    private func digitKey(_ digit: String) -> some View {
        Button {
            guard pin.count < Self.maxDigits else { return }
            pin.append(digit)
            if message != nil, waitUntil == nil { message = nil }
        } label: {
            Text(digit)
                .font(.system(size: 32, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(.white.opacity(0.12), in: .circle)
        }
        .accessibilityLabel(digit)
    }

    private func submit() {
        if let waitUntil, waitUntil > Date() {
            message = Self.waitText(waitUntil)
            return
        }
        let entered = pin
        working = true
        message = nil
        Task {
            let result = await PinLockManager.shared.unlock(pin: entered, model: model)
            working = false
            pin = ""
            switch result {
            case .unlocked:
                break
            case .wrong(let left):
                withAnimation(.default) { shake += 1 }
                if let left {
                    message = left == 0 ? "Wrong PIN. One more wrong PIN erases Relay's messages on this iPhone."
                        : "Wrong PIN. \(left) \(left == 1 ? "try" : "tries") left."
                } else {
                    message = "Wrong PIN."
                }
            case .waitUntil(let date):
                withAnimation(.default) { shake += 1 }
                waitUntil = date
                message = Self.waitText(date)
            case .needsInternet:
                message = "Connect to the internet to unlock Relay."
            case .erased:
                message = nil
            case .failed(let text):
                message = text
            }
        }
    }

    private static func waitText(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow.rounded(.up))
        return seconds >= 60 ? "Too many tries. Try again in \(seconds / 60 + 1) minutes."
            : "Too many tries. Try again in \(max(seconds, 1)) seconds."
    }
}

/// A short side-to-side shake for a wrong PIN.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}
