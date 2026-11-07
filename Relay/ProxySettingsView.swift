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
    /// Signed out (the welcome screen): the onboarding look. Signed in: a
    /// settings page.
    private let onboarding: Bool
    @State private var enabled: Bool
    @State private var address: String
    @State private var checking = false
    @State private var checkResult: ProxyStatus?
    /// The full look at the proxy from the last check.
    @State private var report: ProxyReport?
    @State private var confirmingTrust = false
    @State private var errorMessage: String?

    /// `initialAddress` comes from a shared proxy link.
    init(initialAddress: RelayProxy.Address? = nil, onboarding: Bool = false) {
        self.onboarding = onboarding
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
        Group {
            if onboarding { onboardingLayout } else { settingsForm }
        }
        .confirmationDialog("Do you trust whoever runs this proxy?", isPresented: $confirmingTrust, titleVisibility: .visible) {
            Button("I Trust This Proxy") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trustMessage)
        }
    }

    // MARK: Settings page

    private var settingsForm: some View {
        Form {
            Section {
                SettingsHero(systemName: "network", color: .blue, title: "Proxy",
                             message: "If Relay is blocked where you are, connect through a proxy someone has shared with you.")
                    .settingsBareRow()
            }
            if let backup = model.fallbackHost, !RelayProxy.isEnabled {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Using a backup connection").font(.subheadline.weight(.semibold))
                            Text(backupText(backup)).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                    }
                }
            }
            Section {
                SettingsToggleRow(systemName: "network", color: .blue, title: "Use a Proxy", isOn: $enabled)
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "link", color: .gray)
                    TextField("proxy.example.com", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .onChange(of: address) { _, _ in checkResult = nil; report = nil }
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                if let status = checkResult ?? liveStatus {
                    ProxyStatusRow(status: status)
                }
            } footer: {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            if let report, report.isUsable {
                Section {
                    ProxyReportCard(report: report, inForm: true)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                Label {
                    Text("**Only use a proxy run by someone you trust.** Whoever runs it can see your IP address and when you use Relay, and could keep a record of it. They can't read your messages or see who you talk to.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                }
            }
            Section {
                SettingsPrimaryButton(title: enabled ? "Check and Save" : "Save", color: .blue, working: checking) {
                    Task { await save() }
                }
                .disabled(!(changed && (!enabled || parsed != nil)))
                .settingsBareRow()
            }
            if RelayProxy.isEnabled, !changed {
                Section {
                    if RelayProxy.savedAddress != nil {
                        Button { Task { await checkAgain() } } label: {
                            SettingsNavRow(systemName: "arrow.clockwise", color: .green, title: "Check Again")
                        }
                        .disabled(checking)
                    }
                    if let link = RelayProxy.savedAddress?.shareLink {
                        ShareLink(item: link) {
                            SettingsNavRow(systemName: "square.and.arrow.up", color: .blue, title: "Share This Proxy")
                        }
                    }
                }
                .tint(.primary)
            }
            Section {} footer: { Text(Self.aboutText) }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Proxy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let aboutText = "A Cloudflare Workers address (….workers.dev), like Relay's own backup addresses, works here too. While a proxy is on, Relay never connects directly, keeps checking the proxy in the background, and doesn't fetch link previews. Calls still connect directly."

    private func backupText(_ host: String) -> String {
        "This network seems to block Relay, so Relay is connecting through one of its own backup addresses on Cloudflare. It works like a proxy: Cloudflare sees your IP address, as it does for Relay's main address, and link previews are off until the main address works again. Your messages stay end-to-end encrypted."
    }

    private func checkAgain() async {
        guard let saved = RelayProxy.savedAddress else { return }
        checking = true
        let analysis = await RelayProxy.analyze(saved, relay: RelayConfig.serverURL)
        report = analysis
        checkResult = analysis.status
        model.proxyStatus = analysis.status
        checking = false
    }

    // MARK: Onboarding layout

    private var onboardingLayout: some View {
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
                                .onChange(of: address) { _, _ in checkResult = nil; report = nil }
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

                    if let report, report.isUsable {
                        ProxyReportCard(report: report)
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

                    if RelayProxy.isEnabled, !changed, RelayProxy.savedAddress != nil {
                        textButton("Check Again") { Task { await checkAgain() } }
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

                    Text(Self.aboutText)
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
    }

    private var trustMessage: String {
        var text = "\(parsed?.display ?? "This proxy") will see your IP address and when you use Relay, and could log it. A proxy run by an authority that blocks Relay could use that to find people who use it. Your messages stay end-to-end encrypted."
        if let warnings = report?.warnings, !warnings.isEmpty {
            text += "\n\nThe check also found:\n" + warnings.map { "• " + ProxyReportCard.title($0) }.joined(separator: "\n")
        }
        return text
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
                Text(backupText(host))
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
        let analysis = await RelayProxy.analyze(parsed, relay: RelayConfig.serverURL)
        let status = analysis.status
        checking = false
        checkResult = status
        report = analysis
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

/// What the check found about a proxy: speed, steadiness, where it reaches the
/// internet, and anything that looks off. Warnings inform; they don't block.
struct ProxyReportCard: View {
    let report: ProxyReport
    /// In a settings list rather than on the onboarding gradient.
    var inForm = false

    private var ink: Color { inForm ? .primary : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Proxy check")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            row("speedometer", "Response", latencyText)
            row("arrow.down.circle", "Download", speedText)
            row("waveform.path.ecg", "Steadiness", steadinessText)
            row("globe", "Connects from", locationText)
            if !report.warnings.isEmpty {
                Rectangle().fill(ink.opacity(0.12)).frame(height: 0.5).padding(.horizontal, 16).padding(.vertical, 6)
                ForEach(report.warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(warning)).font(.footnote.weight(.semibold)).foregroundStyle(ink)
                            Text(Self.detail(warning)).font(.caption).foregroundStyle(ink.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                Text("You can still use this proxy. These are things to weigh, not proof it's unsafe.")
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.5))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            } else {
                Label("Nothing unusual found", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if !inForm { Rectangle().fill(.clear).onboardingCard() } }
        .accessibilityElement(children: .combine)
    }

    private func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.footnote).foregroundStyle(ink.opacity(0.5)).frame(width: 20)
            Text(label).font(.footnote).foregroundStyle(ink.opacity(0.7))
            Spacer(minLength: 8)
            Text(value).font(.footnote.weight(.medium)).foregroundStyle(ink).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var latencyText: String {
        guard let ms = report.latencyMs else { return "—" }
        if let direct = report.directLatencyMs { return "\(ms) ms (direct \(direct) ms)" }
        return "\(ms) ms"
    }

    private var speedText: String {
        guard let kbps = report.downloadKBps else { return "—" }
        let text = Self.speed(kbps)
        if let direct = report.directDownloadKBps { return "\(text) (direct \(Self.speed(direct)))" }
        return text
    }

    private var steadinessText: String {
        if report.failedRequests > 0 { return "\(report.failedRequests) requests failed" }
        guard let jitter = report.jitterMs else { return "—" }
        return jitter > RelayProxy.unstableJitterMs ? "Uneven (±\(jitter) ms)" : "Steady (±\(jitter) ms)"
    }

    private var locationText: String {
        if report.viaCloudflareWorker { return "Cloudflare" }
        guard let code = report.exitCountry else { return "Unknown" }
        if code == "T1" { return "Tor network" }
        let name = Locale.current.localizedString(forRegionCode: code) ?? code
        return Self.flag(code) + " " + name
    }

    static func speed(_ kbps: Int) -> String {
        kbps >= 1024 ? String(format: "%.1f MB/s", Double(kbps) / 1024) : "\(kbps) KB/s"
    }

    static func flag(_ code: String) -> String {
        guard code.count == 2 else { return "" }
        return code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
            .map { String($0) }.joined()
    }

    static func title(_ warning: ProxyReport.Warning) -> String {
        switch warning {
        case .slow: "Slow to respond"
        case .throttled: "Very slow downloads"
        case .unstable: "Unsteady connection"
        case .exitsElsewhere: "Passes your connection on"
        case .localNetwork: "On this local network"
        case .tor: "Connects through Tor"
        }
    }

    static func detail(_ warning: ProxyReport.Warning) -> String {
        switch warning {
        case .slow(let ms):
            "Requests take about \(String(format: "%.1f", Double(ms) / 1000)) s. Messages will feel slow."
        case .throttled(let kbps):
            "Downloads ran at \(speed(kbps)). The proxy may be overloaded, or limiting speed on purpose."
        case .unstable:
            "Some requests failed or took much longer than others. Messages may be delayed."
        case .exitsElsewhere:
            "It reaches the internet from a different address than the one you connect to, so another server may see your traffic too."
        case .localNetwork:
            "It's on the network you're connected to, so whoever runs this network may run the proxy, and may be the one blocking Relay."
        case .tor:
            "Its traffic comes out of the Tor network. That hides it well but is often slow and sometimes blocked."
        }
    }
}
