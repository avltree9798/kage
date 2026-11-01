import Foundation
import Testing
import KageModels
@testable import PrivacyKit

@Suite struct CleanupPlannerTests {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let bank = ProtectedSite(domain: "bank.test", allowedDataTypes: [.cookies, .indexedDB])
    let data = [
        WebsiteDataRecord(displayName: "bank.test", kinds: [.cookies, .cache, .indexedDB]),
        WebsiteDataRecord(displayName: "news.test", kinds: [.cookies, .localStorage]),
    ]

    // AT04: protected state preserved, everything else removed.
    @Test func routineCleanupKeepsProtectedKinds() {
        let plan = CleanupPlanner.plan(.init(scope: .routine, now: now, protectedSites: [bank], websiteData: data))
        #expect(plan.steps == [
            .deleteExpiredHistory(asOf: now),
            .deleteExpiredAISessions(asOf: now),
            .removeWebsiteData(displayName: "bank.test", kinds: [.cache]),
            .removeWebsiteData(displayName: "news.test", kinds: [.cookies, .localStorage]),
        ])
        #expect(plan.preserved == ["bank.test": [.cookies, .indexedDB]])
    }

    // AT05: clear all removes protected logins too.
    @Test func everythingIgnoresProtection() {
        let plan = CleanupPlanner.plan(.init(scope: .everything, now: now, protectedSites: [bank], websiteData: data))
        #expect(plan.steps.first == .deleteAllHistory)
        #expect(plan.steps.contains(.removeWebsiteData(displayName: "bank.test", kinds: [.cookies, .cache, .indexedDB])))
        #expect(plan.preserved.isEmpty)
        #expect(plan.steps.last == .removeAllWebsiteDataStores)
    }

    @Test func reportIsIncompleteWhenAnyStepFails() {
        let report = CleanupReport(outcomes: [
            (.deleteAllHistory, .succeeded(count: 3)),
            (.removeWebsiteData(displayName: "x.test", kinds: [.cache]), .failed("timeout")),
        ])
        #expect(!report.isComplete)
    }
}
