#if canImport(WebKit)
import SwiftUI
import UniformTypeIdentifiers
import NetworkTunnel
import KageModels
import PrivacyKit
import SecurityKit
import DesignSystem

/// Spec 9.8: profile, retention, protected sites, last cleanup, AI transmission state and blocking.
/// No tracker counts are shown because WebKit doesn't expose them.
struct PrivacyDashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Current profile") {
                LabeledContent("Profile", value: env.currentProfile.name)
                LabeledContent("History kept", value: retentionText(env.currentProfile.retention))
                ForEach(env.currentProfile.preservationSummary, id: \.self) { Text($0).font(.footnote) }
            }
            Section("Cleanup") {
                if let last = env.lastCleanup {
                    LabeledContent("Last cleanup") { Text(last.ranAt, style: .relative) }
                    Label(last.summary, systemImage: last.complete ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.footnote)
                } else {
                    Text("No cleanup has run yet.").foregroundStyle(.secondary)
                }
                Text("Kage removes its own history exactly on schedule while it's running. Website data held by WebKit is removed by site and type, as WebKit allows; it can't be deleted item by item by age.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Run Cleanup Now") { Task { await env.runCleanup(.manual) } }
            }
            Section("Protected sites") {
                NavigationLink("\(env.protectedSiteList.count) protected site\(env.protectedSiteList.count == 1 ? "" : "s")") { ProtectedSitesView() }
            }
            Section("Context AI") {
                LabeledContent("Account", value: env.aiStatus == .notConfigured ? "Not connected" : "Connected")
                LabeledContent("Automatic summaries", value: env.settings.smartPreSummary ? "On (sensitive sites excluded)" : "Off")
                LabeledContent("Sending now", value: env.context.transmission == nil ? "Nothing" : "Yes")
            }
            Section("Tracking protection") {
                LabeledContent("Content blocking", value: env.settings.blockingMode.rawValue.capitalized)
                LabeledContent("Site exceptions", value: "\(env.settings.blockingExceptions.count)")
                Text("Content blocking applies to pages in Kage only. It isn't a VPN.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Network") {
                NavigationLink { NetworkProtectionView() } label: {
                    Label(env.network.state.title, systemImage: env.network.state.symbol)
                }
            }
            Section {
                NavigationLink("Forget Now…") { ForgetNowView() }.foregroundStyle(.red)
            }
        }
        .navigationTitle("Privacy")
        .kageInlineTitle()
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await env.refreshProtectedSites() }
    }
}

func retentionText(_ r: RetentionInterval) -> String {
    switch r {
    case .onTabClose: "Until the tab closes"
    case .manual: "Until you delete it"
    case .minutes(let m) where m % 1440 == 0: m == 1440 ? "24 hours" : "\(m / 1440) days"
    case .minutes(let m) where m % 60 == 0: m == 60 ? "1 hour" : "\(m / 60) hours"
    case .minutes(let m): "\(m) minutes"
    }
}

struct ProtectedSitesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var newDomain = ""
    @State private var kinds: Set<WebsiteDataKind> = [.cookies, .localStorage, .indexedDB]

    var body: some View {
        Form {
            Section {
                ForEach(env.protectedSiteList) { site in
                    VStack(alignment: .leading) {
                        Text(site.domain + (site.includeSubdomains ? " and subdomains" : ""))
                        Text("Keeps: " + site.allowedDataTypes.map(label).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { Task { await env.unprotect(site) } } }
                    .contextMenu { Button("Remove", role: .destructive) { Task { await env.unprotect(site) } } }
                }
            } footer: {
                Text("Login Keeper is best effort. Kage never stores or replays passwords; some sites will still sign you out.")
            }
            Section("Add a site") {
                TextField("example.com", text: $newDomain).autocorrectionDisabled()
                ForEach(WebsiteDataKind.allCases, id: \.self) { k in
                    Toggle(label(k), isOn: Binding(get: { kinds.contains(k) }, set: { if $0 { kinds.insert(k) } else { kinds.remove(k) } }))
                }
                if let idp = suggestedIdentityProvider {
                    Text("Signing in may also need \(idp.joined(separator: ", ")). Protect those too if you use them.").font(.footnote)
                }
                Button("Protect") {
                    let d = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !d.isEmpty else { return }
                    Task { await env.protect(ProtectedSite(domain: d, allowedDataTypes: kinds)); newDomain = "" }
                }
            }
        }
        .navigationTitle("Protected Sites")
    }

    private var suggestedIdentityProvider: [String]? {
        ProtectedSiteRegistry.identityProviderSuggestions.first { newDomain.lowercased().contains($0.key) }?.value
    }

    private func label(_ k: WebsiteDataKind) -> String {
        switch k {
        case .cookies: "Cookies"
        case .localStorage: "Local storage"
        case .sessionStorage: "Session storage"
        case .indexedDB: "IndexedDB"
        case .cache: "Cache"
        case .serviceWorkers: "Service workers"
        }
    }
}

/// Spec 9.7. Only the most destructive option asks for confirmation; results report partial failure.
struct ForgetNowView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmEverything = false
    @State private var working = false
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                ForEach(ForgetNowAction.allCases) { action in
                    Button(action.title, role: action.requiresConfirmation ? .destructive : nil) {
                        if action.requiresConfirmation { confirmEverything = true } else { run(action, confirmed: false) }
                    }
                    .disabled(working)
                }
            } footer: {
                Text("Deleting data removes it from Kage and WebKit as far as the system allows. It isn't forensic erasure.")
            }
            if working { ProgressView() }
            if let result { Section("Result") { Text(result) } }
        }
        .navigationTitle("Forget Now")
        .confirmationDialog("Clear all browser data?", isPresented: $confirmEverything, titleVisibility: .visible) {
            Button("Clear Everything, Including Protected Logins", role: .destructive) { run(.everything, confirmed: true) }
        } message: { Text("You'll be signed out of every site, and all Kage history, AI chats and temporary tabs are removed.") }
    }

    private func run(_ action: ForgetNowAction, confirmed: Bool) {
        working = true
        result = nil
        Task {
            let r = try? await env.forgetNow.perform(action, confirmed: confirmed)
            result = r?.message ?? "Couldn't complete this action."
            working = false
            await env.refreshProtectedSites()
        }
    }
}

/// Spec 11: honest network status and WARP guidance.
struct NetworkProtectionView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var checking = false
    @State private var working = false
    @State private var pasted = ""
    @State private var importing = false

    var body: some View {
        @Bindable var network = env.network
        Form {
            Section {
                Label(network.state.title, systemImage: network.state.symbol).font(.headline)
                Text(explanation(network.state)).font(.footnote).foregroundStyle(.secondary)
            }
            if network.hasTunnelSupport {
                Section {
                    if network.tunnelInstalled {
                        let on = network.tunnel == .connected || network.tunnel == .connecting || network.tunnel == .reasserting
                        Button(on ? "Disconnect" : "Connect") {
                            Task { working = true; if on { await network.disconnect() } else { await network.connect() }; working = false }
                        }
                        .disabled(working)
                        Button(checking ? "Checking…" : "Check with Cloudflare") {
                            checking = true
                            Task { await network.verify(); checking = false }
                        }
                        .disabled(checking || network.tunnel != .connected)
                        Button("Remove Tunnel", role: .destructive) { Task { await network.removeTunnel() } }
                    } else {
                        TextField("Paste a WireGuard config", text: $pasted, axis: .vertical)
                            .lineLimit(4...10).font(.caption.monospaced()).autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button(working ? "Installing…" : "Install Tunnel") {
                            Task {
                                working = true
                                if await network.importConfig(pasted) { pasted = "" }
                                working = false
                            }
                        }
                        .disabled(working || pasted.isEmpty)
                        Button("Import .conf File…") { importing = true }
                    }
                    if let error = network.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("Kage Tunnel (WireGuard)")
                } footer: {
                    Text("Use a WireGuard config for Cloudflare WARP or another provider. The private key stays in this device's Keychain. The tunnel is a system VPN, so it carries all of this device's traffic while it's on. Kage says \"Protected by WARP\" only when the tunnel is up and Cloudflare confirms the traffic arrives through WARP.")
                }
            }
            Section("Cloudflare WARP app") {
                Toggle("I use the Cloudflare WARP app", isOn: $network.userSaysWARPInstalled)
                Button("Get the 1.1.1.1 + WARP app") {
                    #if os(iOS)
                    openURL(NetworkProtectionMonitor.warpAppStoreURL)
                    #else
                    openURL(NetworkProtectionMonitor.warpDownloadURL)
                    #endif
                }
                if !network.tunnelInstalled {
                    Button(checking ? "Checking…" : "Ask Cloudflare what it sees") {
                        checking = true
                        Task { await network.checkTrace(); checking = false }
                    }
                    .disabled(checking)
                }
                if let note = network.traceNote { Text(note).font(.footnote) }
            }
            Section {
                switch env.dns.status {
                case .notInstalled, .failed:
                    Button("Use Encrypted DNS") { Task { await env.dns.install() } }
                case .installedNotEnabled, .active:
                    Button("Check Again") { Task { await env.dns.refresh() } }
                    Button("Remove Encrypted DNS", role: .destructive) { Task { await env.dns.remove() } }
                case .unavailable:
                    EmptyView()
                }
            } header: {
                Text("Encrypted DNS")
            } footer: {
                Text(env.dns.explanation + " The sites themselves still see your IP address unless the tunnel is on.")
            }
        }
        .task { await env.dns.refresh() }
        .navigationTitle("Network Protection")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 64_000, let text = String(data: data, encoding: .utf8) else { return }
            Task { working = true; _ = await network.importConfig(text, name: url.deletingPathExtension().lastPathComponent); working = false }
        }
    }

    private func explanation(_ state: NetworkProtectionState) -> String {
        switch state {
        case .verifiedConnected: "Kage's tunnel is connected and Cloudflare confirms this traffic arrives through WARP."
        case .tunnelWithoutWARP(let ip): "Kage's tunnel is connected, but Cloudflare doesn't see WARP\(ip.map { " (exit address \($0))" } ?? ""). Your traffic is encrypted to your tunnel provider."
        case .connecting: "Connecting the tunnel…"
        case .disconnected: "The tunnel is installed but off."
        case .restricted: "Turn the Kage VPN profile back on in Settings, or remove and install it again."
        case .statusUnknown(let detail): detail ?? "Kage can't confirm whether Cloudflare WARP is protecting this device, so it doesn't claim you're protected."
        case .notConfigured: "Network Protection is off. Install a WireGuard tunnel below or use Cloudflare's WARP app."
        }
    }
}
#endif
