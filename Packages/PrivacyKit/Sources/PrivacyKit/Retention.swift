import Foundation
import KageModels
import Persistence

/// Spec 9.5 cleanup triggers.
public enum CleanupTrigger: String, Sendable {
    case launch, foreground, interval, tabClosed, sessionEnded, manual, background, lock
}

/// Removes expired Kage-owned records and unprotected website data at permitted times (spec 9.4, 9.5).
/// It never relies on continuous background execution: each trigger is an opportunity, not a promise.
public actor HistoryRetentionActor {
    private let cleaner: WebsiteDataCleaning & Sendable
    private let log: CleanupLogRepository?
    private let protectedSites: @Sendable () async -> [ProtectedSite]
    private let cleanWebsiteDataOnRoutine: @Sendable () async -> Bool
    private let clock: @Sendable () -> Date
    private var intervalTask: Task<Void, Never>?
    private var running = false
    public private(set) var lastReport: CleanupReport?
    public private(set) var lastRun: Date?

    public init(cleaner: WebsiteDataCleaning & Sendable, log: CleanupLogRepository? = nil,
                protectedSites: @escaping @Sendable () async -> [ProtectedSite],
                cleanWebsiteDataOnRoutine: @escaping @Sendable () async -> Bool = { false },
                clock: @escaping @Sendable () -> Date = { .now }) {
        self.cleaner = cleaner; self.log = log; self.protectedSites = protectedSites
        self.cleanWebsiteDataOnRoutine = cleanWebsiteDataOnRoutine; self.clock = clock
    }

    /// Runs one routine pass. Overlapping calls are coalesced so cleanup never runs twice at once.
    @discardableResult
    public func run(trigger: CleanupTrigger, websiteData: [WebsiteDataRecord] = []) async -> CleanupReport? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        let now = clock()
        let sites = await protectedSites()
        let includeWeb = await cleanWebsiteDataOnRoutine()
        let plan = cleaner.plan(using: CleanupPolicy(scope: .routine, now: now, protectedSites: sites,
                                                     websiteData: includeWeb ? websiteData : []))
        let report = await cleaner.execute(plan)
        lastReport = report; lastRun = now
        try? await log?.append(CleanupLogEntry(ranAt: now, trigger: trigger.rawValue, complete: report.isComplete,
                                               summary: report.summary))
        return report
    }

    /// While the app is active, cleans at a fixed cadence (default one minute) so 5-minute retention is honoured closely.
    public func startInterval(every seconds: Double = 60) {
        intervalTask?.cancel()
        intervalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.run(trigger: .interval)
            }
        }
    }

    public func stopInterval() { intervalTask?.cancel(); intervalTask = nil }
}

#if os(iOS)
import BackgroundTasks

/// An opportunistic background refresh; iOS decides if and when it runs (risk register).
/// The launch handler is registered by the app scene's `.backgroundTask(.appRefresh(identifier))`; submitting
/// a request with no registered handler raises an exception, so the scene must register before `schedule()`.
public enum BackgroundCleanupScheduler {
    public static let identifier = "dev.kage.cleanup"

    public static func schedule(after seconds: TimeInterval = 15 * 60) {
        // iPhone and iPad apps running on a Mac have no background refresh.
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try? BGTaskScheduler.shared.submit(req)
    }
}
#endif
