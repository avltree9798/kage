import Foundation
import KageModels

/// Spec 9.7 actions, from least to most destructive.
public enum ForgetNowAction: String, CaseIterable, Sendable, Identifiable {
    case kageHistory
    case unprotectedWebsiteData
    case ephemeralTabs
    case everything

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .kageHistory: "Clear Kage history"
        case .unprotectedWebsiteData: "Clear unprotected website data"
        case .ephemeralTabs: "Close temporary tabs"
        case .everything: "Clear all browser data, including protected logins"
        }
    }
    /// Only the most destructive option needs a confirmation step (AT05).
    public var requiresConfirmation: Bool { self == .everything }
}

public struct ForgetNowResult: Sendable {
    public var action: ForgetNowAction
    public var report: CleanupReport?
    public var tabsClosed: Int
    /// Never claims more than happened: incomplete if any step failed (spec 9.7).
    public var message: String {
        guard let report else { return tabsClosed == 1 ? "Closed 1 tab." : "Closed \(tabsClosed) tabs." }
        return report.isComplete ? "Done. \(report.summary)." : "Partly done. \(report.summary)."
    }
}

public struct ForgetNowService: Sendable {
    let cleaner: WebsiteDataCleanupService
    let protectedSites: @Sendable () async -> [ProtectedSite]
    let closeEphemeralTabs: @Sendable () async -> Int

    public init(cleaner: WebsiteDataCleanupService, protectedSites: @escaping @Sendable () async -> [ProtectedSite],
                closeEphemeralTabs: @escaping @Sendable () async -> Int) {
        self.cleaner = cleaner; self.protectedSites = protectedSites; self.closeEphemeralTabs = closeEphemeralTabs
    }

    public enum ForgetError: Error, Sendable { case confirmationRequired }

    public func perform(_ action: ForgetNowAction, confirmed: Bool = false, now: Date = .now) async throws -> ForgetNowResult {
        if action.requiresConfirmation && !confirmed { throw ForgetError.confirmationRequired }
        switch action {
        case .kageHistory:
            let plan = CleanupPlan(steps: [.deleteAllHistory], preserved: [:])
            return ForgetNowResult(action: action, report: await cleaner.execute(plan), tabsClosed: 0)
        case .unprotectedWebsiteData:
            let records = await cleaner.webKit?.records(of: Set(WebsiteDataKind.allCases)) ?? []
            var plan = cleaner.plan(using: CleanupPolicy(scope: .forgetUnprotected, now: now,
                                                         protectedSites: await protectedSites(), websiteData: records))
            plan.steps.removeAll { $0 == .deleteAllHistory }   // this action leaves history alone
            return ForgetNowResult(action: action, report: await cleaner.execute(plan), tabsClosed: 0)
        case .ephemeralTabs:
            return ForgetNowResult(action: action, report: nil, tabsClosed: await closeEphemeralTabs())
        case .everything:
            let closed = await closeEphemeralTabs()
            let (_, report) = await cleaner.clean(scope: .everything, protectedSites: [], now: now)
            return ForgetNowResult(action: action, report: report, tabsClosed: closed)
        }
    }
}
