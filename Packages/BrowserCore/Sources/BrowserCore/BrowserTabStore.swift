#if canImport(WebKit)
import Foundation
import Observation
import WebKit
import KageModels
import Persistence
import PrivacyKit

/// All logical tabs for the window, with a bounded set of live WebViews (spec 6.2, 13.1 TabManager).
@MainActor @Observable
public final class BrowserTabStore {
    public private(set) var tabs: [TabController] = []
    public private(set) var groups: [TabGroup] = []
    public private(set) var activeTabID: UUID?
    public private(set) var recentlyClosed: [BrowserTab] = []
    public var profile: PrivacyProfile
    public var maxResidentWebViews = TabResidencyPolicy.defaultMaxResident {
        didSet { Task { await enforceResidency() } }
    }
    public var searchEngine: SearchEngine = .duckDuckGo
    public var homeURL: URL?

    @ObservationIgnored public let factory: WebViewFactory
    @ObservationIgnored public let downloads: DownloadManager
    @ObservationIgnored public let permissions: SitePermissionStore
    @ObservationIgnored private let tabRepository: TabRepository?
    @ObservationIgnored private let history: HistoryRepository?
    @ObservationIgnored private let policy: PrivacyPolicyEngine
    @ObservationIgnored public weak var presenter: BrowserPromptPresenting? {
        didSet { tabs.forEach { $0.presenter = presenter } }
    }
    /// Called to open a URL in another app after the user confirmed.
    @ObservationIgnored public var externalOpener: (@MainActor (URL) -> Void)?

    public init(profile: PrivacyProfile, factory: WebViewFactory, downloads: DownloadManager,
                permissions: SitePermissionStore, tabRepository: TabRepository?, history: HistoryRepository?,
                policy: PrivacyPolicyEngine) {
        self.profile = profile; self.factory = factory; self.downloads = downloads; self.permissions = permissions
        self.tabRepository = profile.persistsTabs ? tabRepository : nil
        self.history = history; self.policy = policy
    }

    public var activeTab: TabController? { tabs.first { $0.id == activeTabID } }
    public var residentCount: Int { tabs.filter(\.isResident).count }

    // MARK: Restore and persist

    public func restore() async {
        guard let repo = tabRepository, let saved = try? await repo.loadAll(profileID: profile.id) else { return }
        groups = (try? await repo.loadGroups()) ?? []
        tabs = saved.map { makeController($0) }
        if let last = saved.max(by: { $0.lastActiveAt < $1.lastActiveAt }) { await activate(last.id) }
    }

    public func persist() async {
        guard let repo = tabRepository else { return }
        try? await repo.save(models())
        try? await repo.saveGroups(groups)
    }

    /// The tab list as it would be saved now.
    public func models() -> [BrowserTab] { tabs.enumerated().map { i, t in model(for: t, sortOrder: i) } }

    // MARK: Lock purge (threat model T-11)

    /// Releases every WebView at once, so WebKit ends their content processes, and drops page snapshots.
    /// The tab list stays, and the active tab reloads when Kage is unlocked.
    public func purgeLiveContent() {
        for t in tabs { t.purge(keepState: true) }
    }

    /// Drops the tabs from memory entirely, back/forward state included. The Vault does this on lock;
    /// its tabs come back from the sealed store after the next unlock.
    public func unload() {
        for t in tabs { t.purge(keepState: false) }
        tabs.removeAll(); groups.removeAll(); activeTabID = nil; recentlyClosed.removeAll()
        lastActive.removeAll(); createdAt.removeAll(); pinned.removeAll(); groupMembership.removeAll()
    }

    /// After unlock: brings the active tab's page back.
    public func resumeAfterUnlock() async {
        if let id = activeTabID { await activate(id) }
    }

    func model(for t: TabController, sortOrder: Int) -> BrowserTab {
        BrowserTab(id: t.id, url: t.url, title: t.title, groupID: groupMembership[t.id], profileID: profile.id,
                   createdAt: createdAt[t.id] ?? .now, lastActiveAt: lastActive[t.id] ?? .now,
                   state: t.id == activeTabID ? .active : (t.isResident ? .background : .suspended),
                   isProtected: false, isPinned: pinned.contains(t.id), sortOrder: sortOrder,
                   interactionState: t.persistentState())
    }

    @ObservationIgnored private var lastActive: [UUID: Date] = [:]
    @ObservationIgnored private var createdAt: [UUID: Date] = [:]
    public private(set) var pinned: Set<UUID> = []
    public private(set) var groupMembership: [UUID: UUID] = [:]

    private func makeController(_ tab: BrowserTab) -> TabController {
        let c = TabController(tab: tab, profile: profile)
        c.store = self
        c.presenter = presenter
        lastActive[tab.id] = tab.lastActiveAt
        createdAt[tab.id] = tab.createdAt
        if tab.isPinned { pinned.insert(tab.id) }
        if let g = tab.groupID { groupMembership[tab.id] = g }
        return c
    }

    // MARK: Tab operations (spec 6.2)

    /// Opens a tab. With `background: true` the active Canvas tab stays put (AT12).
    @discardableResult
    public func open(_ url: URL?, in groupID: UUID? = nil, background: Bool = false, after anchor: UUID? = nil) -> UUID {
        let tab = BrowserTab(url: url, title: url?.kageHost ?? "New Tab", groupID: groupID, profileID: profile.id,
                             state: background ? .suspended : .active)
        let c = makeController(tab)
        if let anchor, let i = tabs.firstIndex(where: { $0.id == anchor }) { tabs.insert(c, at: i + 1) } else { tabs.append(c) }
        if !background { Task { await activate(c.id) } }
        Task { await persist() }
        return c.id
    }

    public func openInput(_ text: String, newTab: Bool = false) {
        guard let destination = searchEngine.resolver.resolve(text) else { return }
        let url: URL
        switch destination { case .url(let u), .search(let u): url = u }
        if newTab || activeTab == nil { open(url) } else { activeTab?.load(url) }
    }

    func openPopup(configuration: WKWebViewConfiguration, from source: TabController, request: URLRequest) -> WKWebView {
        let tab = BrowserTab(url: request.url, title: request.url?.kageHost ?? "", profileID: profile.id, state: .active)
        let c = makeController(tab)
        if let i = tabs.firstIndex(where: { $0.id == source.id }) { tabs.insert(c, at: i + 1) } else { tabs.append(c) }
        // WebKit requires the popup to use the configuration it supplied.
        let wv = factory.makeWebView(for: profile, configuration: configuration)
        c.attach(wv)
        activeTabID = c.id
        lastActive[c.id] = .now
        return wv
    }

    public func activate(_ id: UUID) async {
        guard let c = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        lastActive[id] = .now
        if !c.isResident {
            c.attach(factory.makeWebView(for: profile, configuration: factory.configuration(for: profile, desktopMode: c.desktopMode)))
        }
        await enforceResidency()
    }

    public func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let c = tabs[i]
        if profile.persistsTabs { recentlyClosed.insert(model(for: c, sortOrder: i), at: 0); recentlyClosed = Array(recentlyClosed.prefix(20)) }
        Task { await c.detach() }
        tabs.remove(at: i)
        pinned.remove(id); groupMembership[id] = nil
        if activeTabID == id {
            let next = tabs.indices.contains(i) ? tabs[i] : tabs.last
            activeTabID = nil
            if let next { Task { await activate(next.id) } }
        }
        Task {
            try? await tabRepository?.delete(ids: [id])
            onTabClosed?(id)
        }
    }

    /// Called after a tab closes, so the privacy engine can run tab-close retention (spec 9.4, 9.5).
    @ObservationIgnored public var onTabClosed: (@MainActor (UUID) -> Void)?

    public func closeAll(except keep: Set<UUID> = []) { for t in tabs where !keep.contains(t.id) { close(t.id) } }

    public func closeOtherTabs() { if let a = activeTabID { closeAll(except: [a]) } }

    public func reopenLastClosed() {
        guard !recentlyClosed.isEmpty else { return }
        let t = recentlyClosed.removeFirst()
        let c = makeController(t)
        tabs.append(c)
        Task { await activate(c.id) }
    }

    @discardableResult
    public func duplicate(_ id: UUID) -> UUID? {
        guard let c = tabs.first(where: { $0.id == id }) else { return nil }
        let copy = BrowserTab(url: c.url, title: c.title, groupID: groupMembership[id], profileID: profile.id,
                              interactionState: c.persistentState())
        let n = makeController(copy)
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs.insert(n, at: i + 1) }
        return n.id
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { tabs[$0] }
        var remaining = tabs.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        tabs = remaining
        Task { await persist() }
    }

    public func togglePin(_ id: UUID) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        // Pinned tabs sit at the front.
        tabs.sort { pinned.contains($0.id) && !pinned.contains($1.id) }
        Task { await persist() }
    }

    // MARK: Groups (spec 6.3)

    @discardableResult
    public func createGroup(name: String, colour: String, tabIDs: [UUID] = []) -> TabGroup {
        let g = TabGroup(name: name, colour: colour, sortOrder: groups.count, defaultProfileID: profile.id)
        groups.append(g)
        for id in tabIDs { groupMembership[id] = g.id }
        Task { await persist() }
        return g
    }

    public func move(_ tabID: UUID, toGroup groupID: UUID?) {
        groupMembership[tabID] = groupID
        Task { await persist() }
    }

    public func deleteGroup(_ id: UUID, closingTabs: Bool) {
        let members = groupMembership.filter { $0.value == id }.map(\.key)
        if closingTabs { members.forEach(close) } else { members.forEach { groupMembership[$0] = nil } }
        groups.removeAll { $0.id == id }
        Task { await persist() }
    }

    /// Export as a plain URL list, only when the user asks (spec 6.3).
    public func exportGroup(_ id: UUID) -> [URL] {
        tabs.filter { groupMembership[$0.id] == id }.compactMap(\.url)
    }

    public func importGroup(name: String, urls: [URL]) {
        let g = createGroup(name: name, colour: "graphite")
        for u in urls { let tid = open(u, in: g.id, background: true); groupMembership[tid] = g.id }
    }

    public func search(_ text: String) -> [TabController] {
        let q = text.lowercased()
        guard !q.isEmpty else { return tabs }
        return tabs.filter { $0.title.lowercased().contains(q) || ($0.url?.absoluteString.lowercased().contains(q) ?? false) }
    }

    // MARK: Residency and memory (AT02)

    public func enforceResidency() async {
        let resident = tabs.filter(\.isResident).map { model(for: $0, sortOrder: 0) }
        let victims = TabResidencyPolicy.tabsToSuspend(resident: resident, activeID: activeTabID, maxResident: maxResidentWebViews)
        for id in victims { await tabs.first { $0.id == id }?.detach() }
    }

    public func handleMemoryPressure() async {
        maxResidentWebViews = TabResidencyPolicy.lowMemoryMaxResident
        await enforceResidency()
    }

    // MARK: Callbacks from tabs

    func didFinishNavigation(in tab: TabController) {
        guard let url = tab.url, NavigationPolicy.webSchemes.contains(url.scheme?.lowercased() ?? "") else { return }
        let title = tab.title
        let profileID = profile.id
        let history = self.history
        let policy = self.policy
        Task.detached {
            let sitePolicy = await policy.policy(for: url, profileID: profileID)
            guard sitePolicy.recordHistory, let history else { return }
            let now = Date()
            try? await history.recordVisit(HistoryVisit(url: url, title: title, firstVisitedAt: now, lastVisitedAt: now,
                                                        expiresAt: sitePolicy.retention.expiry(after: now),
                                                        isProtected: !sitePolicy.protectedDataKinds.isEmpty))
        }
        Task { await persist() }
    }

    func openExternally(_ url: URL) { externalOpener?(url) }

    /// Closes every tab and discards a nonpersistent store; used when a Private session ends (AT06).
    public func endSession() async -> Int {
        let n = tabs.count
        for t in tabs { await t.detach() }
        tabs.removeAll(); activeTabID = nil; recentlyClosed.removeAll()
        if profile.storeStrategy == .nonPersistent { factory.dataStores.discardNonPersistent(profileID: profile.id) }
        try? await tabRepository?.deleteAll(profileID: profile.id)
        return n
    }
}
#endif
