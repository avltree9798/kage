import Foundation
import Testing
import KageModels
import Persistence
import SecurityKit
@testable import PrivacyKit

actor FakeWebKit: WebsiteDataStoreAdapting {
    var data: [String: Set<WebsiteDataKind>]
    var failFor: String?
    var removedAll = false
    init(_ data: [String: Set<WebsiteDataKind>], failFor: String? = nil) { self.data = data; self.failFor = failFor }
    func records(of kinds: Set<WebsiteDataKind>) -> [WebsiteDataRecord] {
        data.map { WebsiteDataRecord(displayName: $0.key, kinds: $0.value.intersection(kinds)) }
    }
    func remove(_ kinds: Set<WebsiteDataKind>, forDisplayName name: String) throws {
        if name == failFor { throw CancellationError() }
        data[name]?.subtract(kinds)
        if data[name]?.isEmpty == true { data[name] = nil }
    }
    func removeAllStores() { data.removeAll(); removedAll = true }
    func snapshot() -> [String: Set<WebsiteDataKind>] { data }
}

@Suite struct CleanupServiceTests {
    let bank = ProtectedSite(domain: "bank.test", allowedDataTypes: [.cookies])

    // AT04: protected cookies survive; failures are reported, not hidden.
    @Test func protectedCookiesSurviveAndFailuresReported() async throws {
        let web = FakeWebKit(["bank.test": [.cookies, .cache], "news.test": [.cookies], "bad.test": [.cache]], failFor: "bad.test")
        let svc = WebsiteDataCleanupService(history: InMemoryHistoryRepository(), webKit: web)
        let (_, report) = await svc.clean(scope: .forgetUnprotected, protectedSites: [bank])
        #expect(await web.snapshot() == ["bank.test": [.cookies], "bad.test": [.cache]])
        #expect(!report.isComplete)
        #expect(report.failures == [.removeWebsiteData(displayName: "bad.test", kinds: [.cache])])
    }

    @Test func rerunningIsIdempotent() async {
        let web = FakeWebKit(["news.test": [.cookies]])
        let svc = WebsiteDataCleanupService(history: InMemoryHistoryRepository(), webKit: web)
        _ = await svc.clean(scope: .forgetUnprotected, protectedSites: [])
        let (_, second) = await svc.clean(scope: .forgetUnprotected, protectedSites: [])
        #expect(second.isComplete)
        #expect(await web.snapshot().isEmpty)
    }

    // AT05
    @Test func forgetEverythingNeedsConfirmation() async throws {
        let web = FakeWebKit(["bank.test": [.cookies]])
        let svc = ForgetNowService(cleaner: .init(history: InMemoryHistoryRepository(), webKit: web),
                                   protectedSites: { [bank] }, closeEphemeralTabs: { 2 })
        await #expect(throws: ForgetNowService.ForgetError.self) { try await svc.perform(.everything) }
        let result = try await svc.perform(.everything, confirmed: true)
        #expect(result.tabsClosed == 2)
        #expect(await web.removedAll)
        #expect(result.report?.isComplete == true)
    }

    @Test func forgetWebsiteDataLeavesHistory() async throws {
        let history = InMemoryHistoryRepository([HistoryVisit(url: URL(string: "https://a.test")!, firstVisitedAt: .now,
                                                              lastVisitedAt: .now, expiresAt: nil)])
        let svc = ForgetNowService(cleaner: .init(history: history, webKit: FakeWebKit([:])),
                                   protectedSites: { [] }, closeEphemeralTabs: { 0 })
        _ = try await svc.perform(.unprotectedWebsiteData)
        #expect(await history.count == 1)
    }
}

@Suite struct RetentionActorTests {
    @Test func runRemovesExpiredAndLogs() async throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let db = try KageDatabase.inMemory()
        try await db.history.recordVisit(HistoryVisit(url: URL(string: "https://a.test")!, firstVisitedAt: now,
                                                      lastVisitedAt: now, expiresAt: now.addingTimeInterval(-1)))
        let actor = HistoryRetentionActor(cleaner: WebsiteDataCleanupService(history: db.history, aiSessions: db.aiSessions, webKit: nil),
                                          log: db.cleanupLog, protectedSites: { [] }, clock: { now })
        let report = await actor.run(trigger: .launch)
        #expect(report?.isComplete == true)
        #expect(try await db.history.visits(host: nil, limit: 10).isEmpty)
        #expect(try await db.cleanupLog.latest()?.trigger == "launch")
    }
}

@Suite struct PolicyEngineTests {
    @Test func privateProfileNeverAutoSubmitsAI() async {
        var priv = PrivacyProfile.privateSession
        priv.aiAutoProcessing = true
        let engine = PrivacyPolicyEngine(profiles: [priv])
        let p = await engine.policy(for: URL(string: "https://news.test")!, profileID: priv.id)
        #expect(!p.allowAutomaticAI)
        #expect(!p.recordHistory)
    }

    @Test func sensitiveSitesExcludedUnlessOverridden() async {
        var std = PrivacyProfile.standard
        std.aiAutoProcessing = true
        let engine = PrivacyPolicyEngine(profiles: [std])
        let bank = URL(string: "https://www.mybank.test/accounts")!
        #expect(!(await engine.policy(for: bank, profileID: std.id).allowAutomaticAI))
        await engine.setAIOverride(host: "mybank.test", allowed: true)
        #expect(await engine.policy(for: bank, profileID: std.id).allowAutomaticAI)
        #expect(await engine.policy(for: URL(string: "https://news.test")!, profileID: std.id).allowAutomaticAI)
    }

    @Test func protectedSitesKeepHistory() async {
        let engine = PrivacyPolicyEngine(protectedSites: [ProtectedSite(domain: "mail.test")])
        let p = await engine.policy(for: URL(string: "https://mail.test/inbox")!, profileID: PrivacyProfile.ghostID)
        #expect(p.retention == .manual)
    }

    @Test func classifier() {
        #expect(SensitiveSiteClassifier.category(for: URL(string: "https://accounts.google.com/")!) == .authentication)
        #expect(SensitiveSiteClassifier.category(for: URL(string: "https://example.com/login")!) == .authentication)
        #expect(SensitiveSiteClassifier.category(for: URL(string: "https://www.irs.gov/")!) == .government)
        #expect(SensitiveSiteClassifier.category(for: URL(string: "https://swift.org/blog")!) == nil)
    }
}

@MainActor @Suite struct SessionLockTests {
    // AT10: content is concealed before cleanup starts.
    @Test func concealsBeforeCleanup() async {
        final class Box: @unchecked Sendable {
            var concealedDuringCleanup = false
            weak var coordinator: SessionLockCoordinator?
        }
        let box = Box()
        let coordinator = SessionLockCoordinator(mode: .lockAndForget, authenticator: StubAuthenticator(result: true)) { _ in
            let concealed = await MainActor.run { box.coordinator?.isConcealed ?? false }
            box.concealedDuringCleanup = concealed
            return "cleaned"
        }
        box.coordinator = coordinator
        let task = coordinator.lock()
        #expect(coordinator.isConcealed)
        await task?.value
        #expect(box.concealedDuringCleanup)
        #expect(coordinator.lastCleanupMessage == "cleaned")
    }

    @Test func failedAuthenticationStaysLocked() async {
        let c = SessionLockCoordinator(mode: .lockOnly, authenticator: StubAuthenticator(result: false))
        c.lock()
        #expect(!(await c.unlock()))
        #expect(c.isLocked)
    }

    @Test func disabledLockDoesNothing() {
        let c = SessionLockCoordinator(mode: .none, authenticator: StubAuthenticator(result: true))
        c.lock()
        #expect(!c.isLocked)
    }
}
