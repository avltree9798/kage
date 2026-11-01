#if canImport(WebKit)
import SwiftUI
import KageModels
import SecurityKit
import BrowserCore
import ContextAI
import DesignSystem

/// Spec 18.2 settings groups.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var s = env.settings
        Form {
            Section("General") {
                TextField("Home page", text: $s.homepage).autocorrectionDisabled()
                Picker("Default profile", selection: $s.defaultProfile) {
                    Text("Standard").tag(PrivacyProfile.Kind.standard)
                    Text("Ghost").tag(PrivacyProfile.Kind.ghost)
                    Text("Vault").tag(PrivacyProfile.Kind.vault)
                }
            }
            Section("Search") {
                Picker("Search engine", selection: $s.searchEngineID) {
                    ForEach(SearchEngine.all) { Text($0.name).tag($0.id) }
                }
                Toggle("Search suggestions", isOn: $s.searchSuggestions)
                if s.searchSuggestions {
                    Text("What you type in the address bar is sent to \(s.searchEngine.name) to get suggestions. Never in Private.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Tabs") {
                Stepper("Live pages kept in memory: \(env.currentStore.maxResidentWebViews)",
                        value: Binding(get: { env.currentStore.maxResidentWebViews }, set: { env.currentStore.maxResidentWebViews = $0 }), in: 2...12)
                Text("Other tabs are suspended and reload when you open them. Unsaved form entries may be lost.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Accent colour", selection: $s.accentColourName) {
                    ForEach(KageTokens.accents.keys.sorted(), id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Section("Privacy") {
                Picker("History retention", selection: $s.retentionMinutes) {
                    ForEach(AppSettings.retentionChoices, id: \.label) { Text($0.label).tag($0.minutes) }
                }
                .onChange(of: s.retentionMinutes) { _, _ in Task { await env.applyRetentionOverride() } }
                Toggle("Also clear unprotected website data during routine cleanup", isOn: $s.cleanWebsiteDataRoutinely)
                Picker("Tracker blocking", selection: $s.blockingMode) {
                    Text("Off").tag(BlockingMode.off)
                    Text("Standard").tag(BlockingMode.standard)
                    Text("Strict").tag(BlockingMode.strict)
                }
                .onChange(of: s.blockingMode) { _, _ in Task { await env.applyBlockingSettings() } }
                NavigationLink("Protected Sites") { ProtectedSitesView() }
                Picker("Lock", selection: $s.lockMode) {
                    Text("Off").tag(LockPolicy.none)
                    Text("Lock only").tag(LockPolicy.lockOnly)
                    Text("Lock and forget").tag(LockPolicy.lockAndForget)
                    Text("Lock and close temporary session").tag(LockPolicy.lockAndDestroyTemporary)
                }
                .onChange(of: s.lockMode) { _, _ in env.applyLockSettings() }
                if s.lockMode != .none {
                    Toggle("Lock when Kage goes to the background", isOn: $s.lockOnBackground)
                        .onChange(of: s.lockOnBackground) { _, _ in env.applyLockSettings() }
                    Toggle("Lock after inactivity", isOn: $s.lockOnInactivity)
                        .onChange(of: s.lockOnInactivity) { _, _ in env.applyLockSettings() }
                    if s.lockOnInactivity {
                        Stepper("After \(s.inactivityMinutes) min", value: $s.inactivityMinutes, in: 1...60)
                            .onChange(of: s.inactivityMinutes) { _, _ in env.applyLockSettings() }
                    }
                }
            }
            Section("AI and Models") {
                NavigationLink("Cloudflare account") { AIAccountView() }
                Picker("Model", selection: Binding(get: { env.context.modelID }, set: { env.context.modelID = $0; s.aiModelID = $0 })) {
                    ForEach(env.context.registry.models) { Text($0.name).tag($0.id) }
                }
                Toggle("Smart Pre-Summary", isOn: $s.smartPreSummary)
                    .onChange(of: s.smartPreSummary) { _, _ in Task { await env.applyRetentionOverride() } }
                Text("When on, Kage summarises pages after they load. Banking, sign-in and health sites and Private tabs are always skipped.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Passwords and Passkeys") {
                Text("Kage uses your system passwords and passkeys through AutoFill. Kage never stores your passwords.")
                    .font(.footnote)
            }
            Section("Downloads") {
                LabeledContent("Save to", value: env.downloads.directory.lastPathComponent)
            }
            Section("Sync") {
                Toggle("iCloud sync for bookmarks and reading list", isOn: $s.iCloudSync)
                    .disabled(!env.syncAvailable)
                    .onChange(of: s.iCloudSync) { _, on in if on { Task { await env.syncBookmarks() } } }
                if !env.syncAvailable {
                    Text("iCloud sync isn't set up in this build.").font(.footnote).foregroundStyle(.secondary)
                } else if let status = env.syncStatus {
                    Text(status).font(.footnote)
                }
                Text("Private sessions, history and AI chats are never synced. Turning sync off leaves everything on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Network Protection") { NavigationLink(env.network.state.title) { NetworkProtectionView() } }
            Section("Accessibility") {
                Text("Kage follows your system text size, Reduce Motion and contrast settings.").font(.footnote)
            }
            Section("About and Diagnostics") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text("Kage collects no analytics, visited URLs or AI prompts.").font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .kageInlineTitle()
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

/// Cloudflare BYOK (spec 8.1): account ID and scoped token go straight to the Keychain.
struct AIAccountView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var accountID = ""
    @State private var token = ""
    @State private var status: String?
    @State private var working = false
    @State private var hasSaved = false

    var body: some View {
        Form {
            Section {
                TextField("Account ID", text: $accountID).autocorrectionDisabled()
                SecureField("API token (Workers AI read and run)", text: $token)
            } footer: {
                Text("Create a token in the Cloudflare dashboard with only Workers AI permissions. It's stored in this device's Keychain and never synced, logged or shown to web pages.")
            }
            Section {
                Button(working ? "Checking…" : "Save and Test") { Task { await save() } }
                    .disabled(working || accountID.isEmpty || token.isEmpty)
                if hasSaved {
                    Button("Test Connection") { Task { await test() } }.disabled(working)
                    Button("Remove Account", role: .destructive) { Task { await remove() } }
                }
                if let status { Text(status).font(.footnote) }
            }
        }
        .navigationTitle("Cloudflare Workers AI")
        .task {
            if let c = try? await env.credentials.load() { accountID = c.accountID; hasSaved = true }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await env.credentials.save(CloudflareCredential(accountID: accountID.trimmingCharacters(in: .whitespaces),
                                                                apiToken: token.trimmingCharacters(in: .whitespaces)))
            token = ""
            hasSaved = true
            await test()
        } catch {
            status = "Couldn't save to the Keychain."
        }
    }

    private func test() async {
        working = true
        defer { working = false }
        await env.refreshAIStatus()
        status = switch env.aiStatus {
        case .active: "Connected. The token is active."
        case .inactive: "Cloudflare says this token isn't active."
        case .invalid: "Cloudflare didn't accept this token, or Kage couldn't reach it."
        case .notConfigured: "No account saved."
        }
        guard env.aiStatus == .active else { return }
        let ids = ModelRegistry.builtIn.models.map(\.id)
        if let missing = try? await CloudflareAIClient(credentials: env.credentials).unavailableModels(ids), !missing.isEmpty {
            let names = ModelRegistry.builtIn.models.filter { missing.contains($0.id) }.map(\.name).joined(separator: ", ")
            status = (status ?? "") + " Not offered on this account: \(names)."
        }
    }

    private func remove() async {
        try? await env.credentials.delete()
        accountID = ""; hasSaved = false
        await env.refreshAIStatus()
        status = "Removed from this device. Revoke the token in Cloudflare too if you no longer need it."
    }
}

/// First run (spec 18.1). Every optional service can be skipped.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var step = 0

    var body: some View {
        @Bindable var s = env.settings
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                switch step {
                case 0:
                    Text("Welcome to Kage").font(.largeTitle.bold())
                    Text("Kage keeps the sign-ins you choose and lets everything else fade. History expires on your schedule, private tabs leave nothing behind, and AI is off until you connect your own account.")
                    Text("Kage can't promise every site stays signed in, and deleted data isn't forensically erased. The Privacy screen always shows what actually happened.")
                        .font(.footnote).foregroundStyle(.secondary)
                case 1:
                    Text("Choose a default profile").font(.title.bold())
                    Picker("Profile", selection: $s.defaultProfile) {
                        Text("Standard: a normal browser with expiring history").tag(PrivacyProfile.Kind.standard)
                        Text("Ghost: short history, aggressive cleanup").tag(PrivacyProfile.Kind.ghost)
                        Text("Vault: kept until you delete, behind Face ID").tag(PrivacyProfile.Kind.vault)
                    }
                    .pickerStyle(.inline).labelsHidden()
                case 2:
                    Text("How long should history last?").font(.title.bold())
                    Picker("Retention", selection: $s.retentionMinutes) {
                        ForEach(AppSettings.retentionChoices, id: \.label) { Text($0.label).tag($0.minutes) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                case 3:
                    Text("Optional extras").font(.title.bold())
                    NavigationLink("Connect Cloudflare Workers AI") { AIAccountView() }
                    Picker("Lock", selection: $s.lockMode) {
                        Text("No lock").tag(LockPolicy.none)
                        Text("Lock with Face ID or Touch ID").tag(LockPolicy.lockOnly)
                    }
                    if env.syncAvailable { Toggle("iCloud sync for bookmarks", isOn: $s.iCloudSync) }
                    #if os(iOS)
                    Button("Make Kage your default browser") {
                        if let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    #endif
                default:
                    EmptyView()
                }
                Spacer()
                HStack {
                    if step > 0 { Button("Back") { step -= 1 } }
                    Spacer()
                    if step < 3 { Button("Skip") { finish() } }
                    Button(step < 3 ? "Continue" : "Start Browsing") { if step < 3 { step += 1 } else { finish() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    private func finish() {
        env.settings.onboardingComplete = true
        env.applyLockSettings()
        Task {
            await env.applyRetentionOverride()
            if env.settings.defaultProfile != env.currentKind { await env.switchProfile(to: env.settings.defaultProfile) }
        }
    }
}
#if os(iOS)
import UIKit
#endif
#endif
