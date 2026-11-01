import Foundation
import KageModels

/// One site's WebKit data as reported by `WKWebsiteDataStore.fetchDataRecords(ofTypes:)`.
/// Records are grouped by registrable domain and carry no per-item dates (spec 9.2, 9.4).
public struct WebsiteDataRecord: Sendable, Hashable {
    public var displayName: String
    public var kinds: Set<WebsiteDataKind>
    public init(displayName: String, kinds: Set<WebsiteDataKind>) {
        self.displayName = displayName.lowercased(); self.kinds = kinds
    }
}

public enum CleanupScope: Sendable, Equatable {
    /// Expired Kage history plus unprotected website data. Routine cleanup (spec 9.5).
    case routine
    /// Forget Now: all Kage history and unprotected website data (spec 9.7).
    case forgetUnprotected
    /// Forget Now, most destructive: everything, including protected logins. Requires confirmation.
    case everything
}

public struct CleanupPolicy: Sendable {
    public var scope: CleanupScope
    public var now: Date
    public var protectedSites: [ProtectedSite]
    public var websiteData: [WebsiteDataRecord]

    public init(scope: CleanupScope, now: Date, protectedSites: [ProtectedSite], websiteData: [WebsiteDataRecord]) {
        self.scope = scope; self.now = now; self.protectedSites = protectedSites; self.websiteData = websiteData
    }
}

public enum CleanupStep: Sendable, Hashable {
    case deleteExpiredHistory(asOf: Date)
    case deleteAllHistory
    case deleteExpiredAISessions(asOf: Date)
    case deleteAllAISessions
    case removeWebsiteData(displayName: String, kinds: Set<WebsiteDataKind>)
    /// Removes the profile's whole persistent WebKit store, protected logins included (clear all, AT05).
    case removeAllWebsiteDataStores
}

public struct CleanupPlan: Sendable, Equatable {
    public var steps: [CleanupStep]
    /// Sites left untouched (or partly touched) because they are protected; shown to the user (spec 9.3).
    public var preserved: [String: Set<WebsiteDataKind>]
    public init(steps: [CleanupStep], preserved: [String: Set<WebsiteDataKind>] = [:]) {
        self.steps = steps; self.preserved = preserved
    }
}

public enum StepOutcome: Sendable {
    case succeeded(count: Int?)   // count only where observable (spec 13.6 step 5)
    case failed(String)
    case unsupported
}

/// Never claims completion beyond what each step reported (spec 7.4, ADR-010).
public struct CleanupReport: Sendable {
    public var outcomes: [(step: CleanupStep, outcome: StepOutcome)]
    public var isComplete: Bool {
        for o in outcomes { if case .succeeded = o.outcome { continue } else { return false } }
        return true
    }
    public init(outcomes: [(step: CleanupStep, outcome: StepOutcome)]) { self.outcomes = outcomes }

    public var failures: [CleanupStep] {
        var out: [CleanupStep] = []
        for o in outcomes { if case .failed = o.outcome { out.append(o.step) } }
        return out
    }

    /// Plain-language summary for the privacy dashboard. Counts appear only where observable.
    public var summary: String {
        var ok = 0, removed = 0
        for o in outcomes {
            if case .succeeded(let c) = o.outcome { ok += 1; removed += c ?? 0 }
        }
        var parts = ["\(ok) of \(outcomes.count) steps succeeded"]
        if removed > 0 { parts.append("\(removed) Kage records removed") }
        if !failures.isEmpty { parts.append("\(failures.count) will retry next time") }
        return parts.joined(separator: "; ")
    }
}

public protocol WebsiteDataCleaning: Sendable {
    /// Pure and synchronous so AT03 to AT05 can be unit tested without WebKit.
    func plan(using policy: CleanupPolicy) -> CleanupPlan
    /// Idempotent; safe to retry at the next opportunity after a partial failure.
    func execute(_ plan: CleanupPlan) async -> CleanupReport
}

public enum CleanupPlanner {
    public static func plan(_ policy: CleanupPolicy) -> CleanupPlan {
        var steps: [CleanupStep] = []
        var preserved: [String: Set<WebsiteDataKind>] = [:]

        switch policy.scope {
        case .routine:
            steps.append(.deleteExpiredHistory(asOf: policy.now))
            steps.append(.deleteExpiredAISessions(asOf: policy.now))
        case .forgetUnprotected:
            steps.append(.deleteAllHistory)
        case .everything:
            steps.append(.deleteAllHistory)
            steps.append(.deleteAllAISessions)
        }

        for record in policy.websiteData.sorted(by: { $0.displayName < $1.displayName }) {
            var removable = record.kinds
            if policy.scope != .everything,
               let site = policy.protectedSites.first(where: { $0.matches(host: record.displayName) }) {
                let kept = record.kinds.intersection(site.allowedDataTypes)
                if !kept.isEmpty { preserved[record.displayName] = kept }
                removable.subtract(site.allowedDataTypes)
            }
            if !removable.isEmpty {
                steps.append(.removeWebsiteData(displayName: record.displayName, kinds: removable))
            }
        }
        if policy.scope == .everything { steps.append(.removeAllWebsiteDataStores) }
        return CleanupPlan(steps: steps, preserved: preserved)
    }
}
