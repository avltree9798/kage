#if canImport(WebKit)
import Foundation
import Observation
import WebKit
import KageModels
import Persistence
import SecurityKit
import PrivacyKit
import BrowserCore
import ContextAI
import PlatformAdapters
import NetworkTunnel

public enum AppDestination: String, Identifiable, Sendable { case library, privacy, settings; public var id: String { rawValue } }

/// Composition root: builds every service once and wires them together.
@MainActor @Observable
public final class AppEnvironment {
    public let settings: AppSettings
    public let database: KageDatabase
    public let policy: PrivacyPolicyEngine
    public let protectedSites: ProtectedSiteRegistry
    public let contentBlocking: ContentBlockingManager
    public let factory: WebViewFactory
    public let downloads: DownloadManager
    public let permissions: SitePermissionStore
    public let prompts = PromptCenter()
    public let credentials: CredentialStoring
    public let context: ContextCoordinator
    public let lock: SessionLockCoordinator
    public let network = NetworkProtectionMonitor(manager: AppEnvironment.defaultTunnelManager())
    public let capabilities: DeviceCapabilityProviding
    public let retention: HistoryRetentionActor
    public let cleaner: WebsiteDataCleanupService
    @ObservationIgnored public var openExternalURL: (@MainActor (URL) -> Void)?

    public private(set) var stores: [PrivacyProfile.Kind: BrowserTabStore] = [:]
    public private(set) var currentKind: PrivacyProfile.Kind
    public private(set) var protectedSiteList: [ProtectedSite] = []
    public private(set) var lastCleanup: CleanupLogEntry?
    public private(set) var aiStatus: TokenStatus = .notConfigured
    public var isContextVisible = true
    /// The tab sidebar as a column beside the page (wide windows). iPhone shows it full screen instead.
    public var isSidebarVisible = true
    /// Library, Privacy or Settings, opened from the sidebar toolbar or the page menu.
    public var destination: AppDestination?
    /// Mirrors the Vault key gate for the UI. The real gate is `vaultKey`: without the key nothing in the
    /// Vault store can be read, whatever this flag says (threat model T-10).
    public private(set) var vaultUnlocked = false
    /// iOS: true while the screen is being recorded, mirrored or sent over AirPlay.
    public internal(set) var screenIsCaptured = false
    @ObservationIgnored public let vaultKey: any VaultKeyProviding
    @ObservationIgnored public let vault: VaultSealedStore
    @ObservationIgnored public let vaultHistory: VaultHistoryRepository
    @ObservationIgnored public let vaultTabs: VaultTabRepository
    public let dns = EncryptedDNSManager()
    /// UI-test only (see `forLaunch`): tabs to open at start.
    @ObservationIgnored var uiTestTabCount = 0
    @ObservationIgnored var uiTestURL: URL?

    public init(settings: AppSettings = AppSettings(), database: KageDatabase? = nil,
                credentials: CredentialStoring? = nil, capabilities: DeviceCapabilityProviding = DuoCapabilityAdapter(),
                vaultKey: (any VaultKeyProviding)? = nil) {
        self.settings = settings
        let db = database ?? ((try? KageDatabase(store: SQLiteStore.openDefault())) ?? (try! KageDatabase.inMemory()))
        self.database = db
        let key = vaultKey ?? SecureEnclaveVaultKey()
        self.vaultKey = key
        let keySource: VaultKeySource = { try await key.key() }
        // An injected database means tests or UI tests: keep the Vault in memory too.
        let sealed = database == nil ? ((try? VaultSealedStore.openDefault(key: keySource)) ?? (try! VaultSealedStore.inMemory(key: keySource)))
                                     : try! VaultSealedStore.inMemory(key: keySource)
        vault = sealed
        vaultHistory = VaultHistoryRepository(vault: sealed)
        vaultTabs = VaultTabRepository(vault: sealed)
        self.capabilities = capabilities
        let creds = credentials ?? KeychainCredentialStore()
        self.credentials = creds
        policy = PrivacyPolicyEngine()
        protectedSites = ProtectedSiteRegistry(repository: db.protectedSites, history: db.history)
        contentBlocking = ContentBlockingManager(mode: settings.blockingMode, exceptions: Set(settings.blockingExceptions))
        factory = WebViewFactory(contentBlocking: contentBlocking)
        downloads = DownloadManager(repository: db.downloads)
        permissions = SitePermissionStore(repository: db.siteSettings)
        context = ContextCoordinator(client: CloudflareAIClient(credentials: creds), policy: policy, sessions: db.aiSessions)
        currentKind = settings.defaultProfile

        let stores = factory.dataStores
        let profileIDs = PrivacyProfile.builtIn.compactMap { p -> UUID? in
            if case .persistent(let id) = p.storeStrategy { return id } else { return nil }
        }
        let adapter = WebKitDataStoreAdapter(storeIdentifiers: profileIDs, nonPersistent: stores.activeNonPersistentStores)
        cleaner = WebsiteDataCleanupService(history: db.history, aiSessions: db.aiSessions, webKit: adapter)
        let registry = protectedSites
        let settingsRef = settings
        retention = HistoryRetentionActor(cleaner: cleaner, log: db.cleanupLog,
                                          protectedSites: { (try? await registry.all()) ?? [] },
                                          cleanWebsiteDataOnRoutine: { await MainActor.run { settingsRef.cleanWebsiteDataRoutinely } })
        let cleanerRef = cleaner
        lock = SessionLockCoordinator(mode: settings.lockMode, authenticator: BiometricAuthenticator()) { mode in
            switch mode {
            case .lockAndForget:
                let sites = (try? await registry.all()) ?? []
                let (_, report) = await cleanerRef.clean(scope: .routine, protectedSites: sites)
                return report.isComplete ? "Temporary records cleared." : "Some temporary records couldn't be cleared: \(report.summary)."
            default:
                return nil
            }
        }
        context.modelID = settings.aiModelID ?? context.registry.defaultModelID
        context.smartPreSummaryEnabled = settings.smartPreSummary
        context.pages = self
        applyLockSettings()
        lock.onLock = { [weak self] in self?.purgeForLock() }
        lock.onUnlock = { [weak self] in
            guard let self else { return }
            Task { await self.currentStore.resumeAfterUnlock() }
        }
        downloads.resumeHost = { [weak self] in self?.currentStore.activeTab?.webView }
    }

    // MARK: Startup

    /// Kage's WireGuard tunnel exists only in the app bundle that embeds the extension (not in tests).
    nonisolated static func defaultTunnelManager() -> (any TunnelManaging)? {
        #if canImport(NetworkExtension)
        let plugins = Bundle.main.builtInPlugInsURL?.appendingPathComponent("KageTunnel.appex")
        guard let plugins, FileManager.default.fileExists(atPath: plugins.path) else { return nil }
        return SystemTunnelManager.forMainBundle()
        #else
        return nil
        #endif
    }

    public func start() async {
        await network.start()
        await dns.refresh()
        try? await contentBlocking.update(mode: settings.blockingMode, exceptions: Set(settings.blockingExceptions))
        await refreshProtectedSites()
        await applyRetentionOverride()
        await downloads.load()
        await store(for: currentKind).restore()
        if currentStore.tabs.isEmpty { currentStore.open(homeURL) }
        if uiTestTabCount > 0, let url = uiTestURL {
            for i in 0..<uiTestTabCount {
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let items = c?.queryItems ?? []
                c?.queryItems = items + [URLQueryItem(name: "kage-tab", value: String(i))]
                currentStore.open(c?.url ?? url, background: true)
            }
        }
        await runCleanup(.launch)
        await retention.startInterval()
        await syncBookmarks()
        aiStatus = (try? await credentials.load()) == nil ? .notConfigured : .active
        #if os(iOS)
        BackgroundCleanupScheduler.schedule()
        #endif
    }

    public var homeURL: URL? { URL(string: settings.homepage).flatMap { $0.scheme == nil ? nil : $0 } }

    // MARK: Sync (spec 12, optional)

    public var syncAvailable: Bool { CloudKitBookmarkSync.fromBundle() != nil }
    public private(set) var syncStatus: String?

    /// Merges local and iCloud bookmarks. Off unless the user enables it and the build has a container.
    public func syncBookmarks() async {
        guard settings.iCloudSync, let sync = CloudKitBookmarkSync.fromBundle() else { return }
        do {
            let local = try await database.bookmarks.all(folderID: nil, readingList: nil)
            let merged = SyncMerge.merge(local: local, remote: try await sync.pull())
            for b in merged where !local.contains(b) { try await database.bookmarks.save(b) }
            try await sync.push(merged)
            syncStatus = "Synced \(merged.count) bookmarks."
        } catch {
            syncStatus = "iCloud sync didn't finish. Local bookmarks are unchanged."
        }
    }

    // MARK: Profiles (spec 9.6)

    public var currentStore: BrowserTabStore { store(for: currentKind) }
    public var currentProfile: PrivacyProfile { currentStore.profile }

    public func store(for kind: PrivacyProfile.Kind) -> BrowserTabStore {
        if let s = stores[kind] { return s }
        let profile = PrivacyProfile.builtIn.first { $0.kind == kind } ?? .standard
        let isVault = kind == .vault
        let s = BrowserTabStore(profile: profile, factory: factory, downloads: downloads, permissions: permissions,
                                tabRepository: isVault ? vaultTabs : database.tabs,
                                history: isVault ? vaultHistory : database.history, policy: policy)
        s.presenter = prompts
        s.searchEngine = settings.searchEngine
        s.homeURL = homeURL
        s.externalOpener = { [weak self] url in self?.openExternalURL?(url) }
        s.onTabClosed = { [weak self] _ in
            guard let self else { return }
            Task { await self.runCleanup(.tabClosed) }
        }
        stores[kind] = s
        return s
    }

    /// Switching profile. Vault asks for authentication first; leaving Private discards its session.
    public func switchProfile(to kind: PrivacyProfile.Kind) async {
        guard kind != currentKind else { return }
        if kind == .vault {
            // The Secure Enclave releases the key only after Face ID, Touch ID or the passcode.
            guard (try? await vaultKey.unlock(reason: "Open your Vault")) != nil else { return }
            vaultUnlocked = true
        }
        let leaving = currentKind
        currentKind = kind
        let s = store(for: kind)
        if s.tabs.isEmpty { await s.restore() }
        if s.tabs.isEmpty { s.open(homeURL) }
        if leaving == .private { _ = await endPrivateSession() }
        if leaving == .vault { lockVault() }
    }

    /// History for the Library: the Vault's sealed history while in the Vault, the main one otherwise.
    public var currentHistory: any HistoryRepository { currentKind == .vault ? vaultHistory : database.history }

    // MARK: Lock purge (threat model T-11)

    /// Runs synchronously on every lock, right after the content is concealed.
    func purgeForLock() {
        for s in stores.values { s.purgeLiveContent() }
        lockVault()
        context.clear()
        URLCache.shared.removeAllCachedResponses()
    }

    /// Takes the Vault's tabs out of memory, saves them sealed, forgets the key and empties the Vault's
    /// WebKit caches. Called on lock, on leaving the Vault and when Kage goes to the background.
    public func lockVault() {
        if let s = stores[.vault] {
            let models = s.models()
            s.unload()
            stores[.vault] = nil
            if currentKind == .vault {
                currentKind = .standard
                let standard = store(for: .standard)
                if standard.tabs.isEmpty { Task { await standard.restore(); if standard.tabs.isEmpty { standard.open(homeURL) } } }
            }
            let tabs = vaultTabs
            Task { try? await tabs.save(models) ; await self.forgetVaultKey() }
        } else {
            Task { await forgetVaultKey() }
        }
        vaultUnlocked = false
        if let vaultProfile = PrivacyProfile.builtIn.first(where: { $0.kind == .vault }) {
            factory.dataStores.store(for: vaultProfile).removeData(
                ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
                modifiedSince: .distantPast) {}
        }
    }

    private func forgetVaultKey() async { await vaultKey.lock() }

    /// AT06: closing the private session drops its tabs and its in-memory WebKit store.
    @discardableResult
    public func endPrivateSession() async -> Int {
        guard let s = stores[.private] else { return 0 }
        let n = await s.endSession()
        stores[.private] = nil
        return n
    }

    public func openNewPrivateWindow() async { await switchProfile(to: .private) }

    // MARK: Privacy

    public func refreshProtectedSites() async {
        protectedSiteList = (try? await protectedSites.all()) ?? []
        await policy.update(protectedSites: protectedSiteList)
        lastCleanup = try? await database.cleanupLog.latest()
    }

    public func protect(_ site: ProtectedSite) async {
        try? await protectedSites.protect(site)
        await refreshProtectedSites()
    }

    public func unprotect(_ site: ProtectedSite) async {
        try? await protectedSites.unprotect(site)
        await refreshProtectedSites()
    }

    public func applyRetentionOverride() async {
        for var p in PrivacyProfile.builtIn where p.kind != .private {
            if let r = settings.retentionOverride, p.kind == settings.defaultProfile { p.retention = r }
            p.aiAutoProcessing = settings.smartPreSummary
            await policy.update(profile: p)
        }
        context.smartPreSummaryEnabled = settings.smartPreSummary
    }

    public func runCleanup(_ trigger: CleanupTrigger) async {
        await retention.run(trigger: trigger, websiteData: [])
        lastCleanup = try? await database.cleanupLog.latest()
    }

    public var forgetNow: ForgetNowService {
        let registry = protectedSites
        return ForgetNowService(cleaner: cleaner, protectedSites: { (try? await registry.all()) ?? [] },
                                closeEphemeralTabs: { [weak self] in await self?.closeEphemeralTabs() ?? 0 })
    }

    /// Ghost and Private tabs are the temporary ones (spec 9.7).
    func closeEphemeralTabs() async -> Int {
        var n = 0
        if let g = stores[.ghost] { n += g.tabs.count; g.closeAll() }
        n += await endPrivateSession()
        return n
    }

    public func applyLockSettings() {
        lock.mode = settings.lockMode
        var t: LockTriggers = [.manual, .deviceLock, .deviceClose]
        if settings.lockOnBackground { t.insert(.appBackground) }
        if settings.lockOnInactivity { t.insert(.inactivity) }
        lock.triggers = t
        lock.inactivityTimeout = .seconds(settings.inactivityMinutes * 60)
    }

    public func applyBlockingSettings() async {
        try? await contentBlocking.update(mode: settings.blockingMode, exceptions: Set(settings.blockingExceptions))
        for s in stores.values { for t in s.tabs { if let wv = t.webView { contentBlocking.apply(to: wv.configuration.userContentController) } } }
    }

    public func refreshAIStatus() async {
        aiStatus = (try? await CloudflareAIClient(credentials: credentials).validate()) ?? .invalid
    }

    // MARK: Throw to Context (spec 7.2, AT12)

    public enum ThrowTarget: Sendable { case backgroundTab, summarise, research, bookmark, readingList, note }

    /// Never replaces the active Canvas tab unless the user asks.
    public func throwToContext(_ url: URL, target: ThrowTarget, title: String? = nil) async {
        let store = currentStore
        switch target {
        case .backgroundTab:
            store.open(url, background: true, after: store.activeTabID)
        case .summarise:
            let id = store.open(url, background: true, after: store.activeTabID)
            isContextVisible = true
            await prepareBackground(id)
            context.summarise(tabID: id)
        case .research:
            let id = store.open(url, background: true, after: store.activeTabID)
            context.addToResearch(id)
            isContextVisible = true
        case .bookmark:
            try? await database.bookmarks.save(Bookmark(url: url, title: title ?? url.kageHost))
        case .readingList:
            try? await database.bookmarks.save(Bookmark(url: url, title: title ?? url.kageHost, isReadingList: true))
        case .note:
            await context.saveNote(title ?? url.absoluteString, source: url)
        }
    }

    /// Loads a background tab enough to read it, without changing the active tab.
    func prepareBackground(_ id: UUID) async {
        let store = currentStore
        guard let tab = store.tabs.first(where: { $0.id == id }) else { return }
        if !tab.isResident {
            let active = store.activeTabID
            await store.activate(id)
            if let active { await store.activate(active) }
        }
        for _ in 0..<100 where tab.isLoading || tab.url == nil { try? await Task.sleep(for: .milliseconds(100)) }
    }
}

extension AppEnvironment: PageContentProviding {
    public func extractedContent(tabID: UUID, maxBytes: Int) async -> ExtractedContent? {
        for s in stores.values {
            guard let tab = s.tabs.first(where: { $0.id == tabID }) else { continue }
            if !tab.isResident { await prepareBackground(tabID) }
            guard let url = tab.url else { return nil }
            if maxBytes <= 1 { return ExtractedContent(sourceURL: url, title: tab.title, text: "") }
            if let reader = await tab.readerDocument(), reader.isUsable {
                return ExtractedContent(sourceURL: url, title: reader.title.isEmpty ? tab.title : reader.title, text: reader.text)
            }
            guard let text = await tab.pageText(maxChars: maxBytes) else { return nil }
            return ExtractedContent(sourceURL: url, title: text.title, text: text.text)
        }
        return nil
    }

    public func profileID(for tabID: UUID) -> UUID {
        stores.values.first { $0.tabs.contains { $0.id == tabID } }?.profile.id ?? currentProfile.id
    }
}
#endif
