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
        Form {
            Section {
                Toggle("Use a Proxy", isOn: $enabled)
                TextField("proxy.example.com", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .disabled(!enabled)
                    .onChange(of: address) { _, _ in checkResult = nil }
                if let status = checkResult ?? liveStatus {
                    ProxyStatusRow(status: status)
                }
            } footer: {
                Text(errorMessage ?? "If Relay is blocked where you are, connect through a proxy someone has shared with you. While a proxy is on, Relay never connects directly, and it keeps checking the proxy in the background. Calls still connect directly.")
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
            }

            Section {
                Label {
                    Text("**Only use a proxy run by someone you trust.** Whoever runs it can see your IP address and when you use Relay, and could keep a record of it. They can't read your messages or see who you talk to.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                }
            }

            if let link = RelayProxy.savedAddress?.shareLink, RelayProxy.isEnabled {
                Section {
                    ShareLink(item: link) {
                        Label("Share This Proxy", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text(enabled ? "Check and Save" : "Save")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(!changed || checking || (enabled && parsed == nil))
                if RelayProxy.isEnabled, !changed, let saved = RelayProxy.savedAddress {
                    Button("Check Again") {
                        Task {
                            checking = true
                            checkResult = await RelayProxy.check(saved, relay: RelayConfig.serverURL)
                            model.proxyStatus = checkResult
                            checking = false
                        }
                    }
                    .disabled(checking)
                }
            }
        }
        .navigationTitle("Proxy")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Do you trust whoever runs this proxy?", isPresented: $confirmingTrust, titleVisibility: .visible) {
            Button("I Trust This Proxy") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(parsed?.display ?? "This proxy") will see your IP address and when you use Relay, and could log it. A proxy run by an authority that blocks Relay could use that to find people who use it. Your messages stay end-to-end encrypted.")
        }
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
