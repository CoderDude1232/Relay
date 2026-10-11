//
//  ProxySettingsView.swift
//  Relay
//
//  Settings → Privacy → Proxy, also reachable from the welcome screen so
//  someone who can't reach Relay can still sign in.
//

import RelayKit
import SwiftUI

struct ProxySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = RelayProxy.isEnabled
    @State private var address = RelayProxy.savedAddress?.display ?? ""
    @State private var applying = false
    @State private var errorMessage: String?

    private var parsed: RelayProxy.Address? { RelayProxy.parse(address) }
    private var changed: Bool {
        enabled != RelayProxy.isEnabled || parsed != RelayProxy.savedAddress
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
            } footer: {
                Text(errorMessage ?? "If Relay is blocked where you are, connect through a proxy someone has shared with you. Your messages stay end-to-end encrypted, and the proxy can't read them or see who you talk to. While a proxy is on, Relay never connects directly. Calls still connect directly.")
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
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
                    Task { await apply() }
                } label: {
                    HStack {
                        Text("Save")
                        if applying { Spacer(); ProgressView() }
                    }
                }
                .disabled(!changed || applying || (enabled && parsed == nil))
            }
        }
        .navigationTitle("Proxy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func apply() async {
        errorMessage = nil
        if enabled && parsed == nil {
            errorMessage = "That doesn't look like a proxy address."
            return
        }
        applying = true
        defer { applying = false }
        RelayProxy.save(enabled ? parsed : RelayProxy.savedAddress, enabled: enabled)
        await model.applyProxyChange()
    }
}
