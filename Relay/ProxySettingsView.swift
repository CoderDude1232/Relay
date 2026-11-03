//
//  ProxySettingsView.swift
//  Relay
//
//  Settings → Privacy → Proxy, also reachable from the welcome screen so
//  someone who can't reach Relay can still sign in. A proxy is checked before
//  it's used, and only saved after the user confirms they trust whoever runs
//  it, since a proxy sees their IP address.
//

import RelayKit
import SwiftUI

struct ProxySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var enabled: Bool
    @State private var address: String
    @State private var checking = false
    @State private var checkResult: ProxyStatus?
    @State private var confirmingTrust = false
    @State private var errorMessage: String?

    /// `initialAddress` comes from a shared proxy link.
    init(initialAddress: RelayProxy.Address? = nil) {
        _enabled = State(initialValue: initialAddress != nil || RelayProxy.isEnabled)
        _address = State(initialValue: initialAddress?.display ?? RelayProxy.savedAddress?.display ?? "")
    }

    private var parsed: RelayProxy.Address? { RelayProxy.parse(address) }
    private var changed: Bool {
        enabled != RelayProxy.isEnabled || (enabled && parsed != RelayProxy.savedAddress)
    }
    /// The live status for the proxy that's saved and on.
    private var liveStatus: ProxyStatus? {
        RelayProxy.isEnabled && parsed == RelayProxy.savedAddress ? model.proxyStatus : nil
    }

    var body: some View {
        ZStack {
            BackgroundGradient().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    OnboardingHeader(
                        title: "Proxy",
                        subtitle: "If Relay is blocked where you are, connect through a proxy someone has shared with you."
                    )

                    if let backup = model.fallbackHost, !RelayProxy.isEnabled {
                        backupNotice(backup)
                    }

                    VStack(spacing: 0) {
                        OnboardingRow(icon: "network") {
                            Toggle("Use a Proxy", isOn: $enabled)
                                .foregroundStyle(.white)
                                .tint(Color(red: 0.965, green: 0.231, blue: 1.0))
                        }
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.leading, 52).padding(.trailing, 16)
                        OnboardingRow(icon: "link") {
                            TextField("", text: $address, prompt: Text("proxy.example.com").foregroundStyle(.white.opacity(0.35)))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .foregroundStyle(.white)
                                .tint(.white)
                                .disabled(!enabled)
                                .onChange(of: address) { _, _ in checkResult = nil }
                        }
                        .opacity(enabled ? 1 : 0.45)
                        if let status = checkResult ?? liveStatus {
                            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.leading, 52).padding(.trailing, 16)
                            ProxyStatusRow(status: status)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .onboardingCard()

                    if let errorMessage {
                        InlineErrorBanner(errorMessage)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 17))
                        Text("**Only use a proxy run by someone you trust.** Whoever runs it can see your IP address and when you use Relay, and could keep a record of it. They can't read your messages or see who you talk to.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onboardingCard()

                    OnboardingPrimaryButton(title: enabled ? "Check and Save" : "Save",
                                            enabled: changed && (!enabled || parsed != nil),
                                            working: checking) {
                        Task { await save() }
                    }

                    if RelayProxy.isEnabled, !changed, let saved = RelayProxy.savedAddress {
                        textButton("Check Again") {
                            Task {
                                checking = true
                                checkResult = await RelayProxy.check(saved, relay: RelayConfig.serverURL)
                                model.proxyStatus = checkResult
                                checking = false
                            }
                        }
                        .disabled(checking)
                    }
                    if let link = RelayProxy.savedAddress?.shareLink, RelayProxy.isEnabled {
                        ShareLink(item: link) {
                            Label("Share This Proxy", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(minHeight: 44)
                        }
                    }

                    Text("While a proxy is on, Relay never connects directly, keeps checking the proxy in the background, and doesn't fetch link previews. Calls still connect directly.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 120)  // clear of the tab bar
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Do you trust whoever runs this proxy?", isPresented: $confirmingTrust, titleVisibility: .visible) {
            Button("I Trust This Proxy") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(parsed?.display ?? "This proxy") will see your IP address and when you use Relay, and could log it. A proxy run by an authority that blocks Relay could use that to find people who use it. Your messages stay end-to-end encrypted.")
        }
    }

    /// Relay switched to one of its own backup addresses because this network
    /// blocks the main one: it works like a proxy, run by Relay.
    private func backupNotice(_ host: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.orange)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 4) {
                Text("Using a backup connection")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("This network seems to block Relay, so Relay is connecting through one of its own backup addresses on Cloudflare. It works like a proxy: Cloudflare sees your IP address, as it does for Relay's main address, and link previews are off until the main address works again. Your messages stay end-to-end encrypted.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(minHeight: 44)
    }

    private func save() async {
        errorMessage = nil
        guard enabled else {
            RelayProxy.save(RelayProxy.savedAddress, enabled: false)
            await model.applyProxyChange()
            return
        }
        guard let parsed else {
            errorMessage = "That doesn't look like a proxy address."
            return
        }
        checking = true
        let status = await RelayProxy.check(parsed, relay: RelayConfig.serverURL)
        checking = false
        checkResult = status
        switch status {
        case .ok, .slow:
            confirmingTrust = true
        case .unreachable:
            errorMessage = "Couldn't reach that proxy. Check the address, or try another proxy."
        case .refused:
            errorMessage = "That proxy wouldn't connect to Relay. It may be blocking Relay or set up wrongly."
        case .securityFailure:
            errorMessage = "This proxy failed a security check, which can mean someone is tampering with the connection. It hasn't been saved. Don't use it."
        }
    }

    private func apply() async {
        guard let parsed else { return }
        RelayProxy.save(parsed, enabled: true)
        await model.applyProxyChange()
    }
}

/// One line describing a proxy check.
struct ProxyStatusRow: View {
    let status: ProxyStatus

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch status {
        case .ok(let ms): "Working · \(ms) ms"
        case .slow(let ms): "Slow · \(String(format: "%.1f", Double(ms) / 1000)) s per request"
        case .unreachable: "Can't reach the proxy"
        case .refused: "The proxy is blocking Relay"
        case .securityFailure: "Security check failed — possible tampering"
        }
    }

    private var symbol: String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .slow: "tortoise.fill"
        case .unreachable, .refused: "xmark.octagon.fill"
        case .securityFailure: "exclamationmark.shield.fill"
        }
    }

    private var color: Color {
        switch status {
        case .ok: .green
        case .slow: .orange
        case .unreachable, .refused, .securityFailure: .red
        }
    }
}
