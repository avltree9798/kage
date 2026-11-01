import Foundation
import KageModels
import Persistence

/// The WebKit operations cleanup needs, behind a protocol so the executor is testable without WebKit.
public protocol WebsiteDataStoreAdapting: Sendable {
    func records(of kinds: Set<WebsiteDataKind>) async -> [WebsiteDataRecord]
    func remove(_ kinds: Set<WebsiteDataKind>, forDisplayName name: String) async throws
    func removeAllStores() async throws
}

/// Executes a `CleanupPlan` (spec 13.6). Each step runs independently, so one failure
/// never blocks the rest, and re-running the same plan is safe (ADR-010).
public struct WebsiteDataCleanupService: WebsiteDataCleaning {
    let history: HistoryRepository
    let aiSessions: AISessionRepository?
    let webKit: WebsiteDataStoreAdapting?

    public init(history: HistoryRepository, aiSessions: AISessionRepository? = nil, webKit: WebsiteDataStoreAdapting?) {
        self.history = history; self.aiSessions = aiSessions; self.webKit = webKit
    }

    public func plan(using policy: CleanupPolicy) -> CleanupPlan { CleanupPlanner.plan(policy) }

    public func execute(_ plan: CleanupPlan) async -> CleanupReport {
        var outcomes: [(step: CleanupStep, outcome: StepOutcome)] = []
        for step in plan.steps {
            outcomes.append((step, await run(step)))
        }
        return CleanupReport(outcomes: outcomes)
    }

    /// Builds and executes a plan using live WebKit records.
    public func clean(scope: CleanupScope, protectedSites: [ProtectedSite], now: Date = .now) async -> (CleanupPlan, CleanupReport) {
        let records = await webKit?.records(of: Set(WebsiteDataKind.allCases)) ?? []
        let p = plan(using: CleanupPolicy(scope: scope, now: now, protectedSites: protectedSites, websiteData: records))
        return (p, await execute(p))
    }

    private func run(_ step: CleanupStep) async -> StepOutcome {
        do {
            switch step {
            case .deleteExpiredHistory(let date):
                return .succeeded(count: try await history.deleteExpired(asOf: date))
            case .deleteAllHistory:
                return .succeeded(count: try await history.deleteAll(includingProtected: true))
            case .deleteExpiredAISessions(let date):
                guard let aiSessions else { return .unsupported }
                return .succeeded(count: try await aiSessions.deleteExpired(asOf: date))
            case .deleteAllAISessions:
                guard let aiSessions else { return .unsupported }
                try await aiSessions.deleteAll()
                return .succeeded(count: nil)
            case .removeWebsiteData(let name, let kinds):
                guard let webKit else { return .unsupported }
                try await webKit.remove(kinds, forDisplayName: name)
                return .succeeded(count: nil)   // WebKit does not report item counts
            case .removeAllWebsiteDataStores:
                guard let webKit else { return .unsupported }
                try await webKit.removeAllStores()
                return .succeeded(count: nil)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }
}

#if canImport(WebKit)
import WebKit

extension WebsiteDataKind {
    var webKitTypes: Set<String> {
        switch self {
        case .cookies: [WKWebsiteDataTypeCookies]
        case .localStorage: [WKWebsiteDataTypeLocalStorage]
        case .sessionStorage: [WKWebsiteDataTypeSessionStorage]
        case .indexedDB: [WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases]
        case .cache: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache,
                      WKWebsiteDataTypeFetchCache]
        case .serviceWorkers: [WKWebsiteDataTypeServiceWorkerRegistrations]
        }
    }

    static func kinds(for types: Set<String>) -> Set<WebsiteDataKind> {
        Set(allCases.filter { !$0.webKitTypes.isDisjoint(with: types) })
    }
}

extension Set where Element == WebsiteDataKind {
    var webKitTypes: Set<String> { reduce(into: []) { $0.formUnion($1.webKitTypes) } }
}

/// Real adapter over the profile's `WKWebsiteDataStore`s (spec 9.2: cookies live in its `httpCookieStore`).
@MainActor public final class WebKitDataStoreAdapter: WebsiteDataStoreAdapting {
    private let storeIdentifiers: [UUID]
    private let nonPersistent: [WKWebsiteDataStore]

    public init(storeIdentifiers: [UUID], nonPersistent: [WKWebsiteDataStore] = []) {
        self.storeIdentifiers = storeIdentifiers; self.nonPersistent = nonPersistent
    }

    private var stores: [WKWebsiteDataStore] {
        storeIdentifiers.map { WKWebsiteDataStore(forIdentifier: $0) } + nonPersistent
    }

    public func records(of kinds: Set<WebsiteDataKind>) async -> [WebsiteDataRecord] {
        var merged: [String: Set<WebsiteDataKind>] = [:]
        for store in stores {
            let recs = await store.dataRecords(ofTypes: kinds.webKitTypes)
            for r in recs { merged[r.displayName.lowercased(), default: []].formUnion(WebsiteDataKind.kinds(for: r.dataTypes)) }
        }
        return merged.map { WebsiteDataRecord(displayName: $0.key, kinds: $0.value) }
    }

    public func remove(_ kinds: Set<WebsiteDataKind>, forDisplayName name: String) async throws {
        let types = kinds.webKitTypes
        for store in stores {
            let matching = await store.dataRecords(ofTypes: types).filter { $0.displayName.lowercased() == name }
            if !matching.isEmpty { await store.removeData(ofTypes: types, for: matching) }
        }
    }

    public func removeAllStores() async throws {
        for store in stores {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
}
#endif
