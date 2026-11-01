#if canImport(WebKit)
import SwiftUI
import KageModels
import DesignSystem
import Persistence
import SecurityKit

extension AppEnvironment {
    /// `-KageUITesting` (UI tests only) starts with onboarding done, a throwaway settings suite, an in-memory
    /// database and no Keychain access, so tests never touch the user's real data. `-KageUITestTabs N` opens N
    /// tabs of `KAGE_UITEST_URL` (default https://example.com/) for the 100-tab memory test.
    static func forLaunch(_ process: ProcessInfo = .processInfo) -> AppEnvironment {
        guard process.arguments.contains("-KageUITesting") else { return AppEnvironment() }
        let suite = "dev.kage.uitests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.onboardingComplete = true
        settings.homepage = "about:blank"
        let env = AppEnvironment(settings: settings, database: try? KageDatabase.inMemory(), credentials: InMemoryCredentialStore())
        if let i = process.arguments.firstIndex(of: "-KageUITestTabs"), i + 1 < process.arguments.count,
           let n = Int(process.arguments[i + 1]) {
            env.uiTestTabCount = min(n, 200)
            env.uiTestURL = process.environment["KAGE_UITEST_URL"].flatMap(URL.init(string:)) ?? URL(string: "https://example.com/")!
        }
        return env
    }
}

/// The app's scene, shared by the iOS/iPadOS and macOS targets.
public struct KageScene: Scene {
    @State private var env = AppEnvironment.forLaunch()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .tint(KageTokens.accents[env.settings.accentColourName] ?? .accentColor)
                // Default-browser links and Handoff land here (spec 12).
                .onOpenURL { url in env.currentStore.open(url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { env.currentStore.open(url) }
                }
                .task {
                    #if os(iOS)
                    env.openExternalURL = { url in UIApplication.shared.open(url) }
                    #else
                    env.openExternalURL = { url in _ = NSWorkspace.shared.open(url) }
                    #endif
                }
                .userActivity(NSUserActivityTypeBrowsingWeb, isActive: handoffAllowed) { activity in
                    activity.webpageURL = env.currentStore.activeTab?.url
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { env.currentStore.open(env.homeURL) }.keyboardShortcut("t")
                Button("New Private Tab") { Task { await env.openNewPrivateWindow() } }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Reopen Closed Tab") { env.currentStore.reopenLastClosed() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Close Tab") { if let id = env.currentStore.activeTabID { env.currentStore.close(id) } }.keyboardShortcut("w")
            }
            CommandMenu("Privacy") {
                Button("Lock Kage") { env.lock.lock(trigger: .manual) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Run Cleanup Now") { Task { await env.runCleanup(.manual) } }
            }
        }
    }

    /// Handoff only for ordinary web pages in Standard; never Private, Ghost or Vault (spec 12).
    private var handoffAllowed: Bool {
        guard env.currentKind == .standard, let scheme = env.currentStore.activeTab?.url?.scheme else { return false }
        return scheme == "https" || scheme == "http"
    }
}
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#endif
