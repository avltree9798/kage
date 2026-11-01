import Foundation
import Testing
import KageModels
@testable import Persistence

@Suite struct SQLiteHistoryTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func visit(_ s: String, title: String = "", expiresIn seconds: TimeInterval? = 60) -> HistoryVisit {
        HistoryVisit(url: URL(string: s)!, title: title, firstVisitedAt: now, lastVisitedAt: now,
                     expiresAt: seconds.map { now.addingTimeInterval($0) })
    }

    @Test func migrationsSetSchemaVersion() async throws {
        let db = try KageDatabase.inMemory()
        #expect(try await db.store.schemaVersion == Schema.migrations.map(\.version).max())
    }

    @Test func upsertCountsRepeatVisits() async throws {
        let repo = try KageDatabase.inMemory().history
        try await repo.recordVisit(visit("https://swift.org/blog", title: "Swift Blog"))
        try await repo.recordVisit(visit("https://swift.org/blog"))
        let found = try await repo.search("swift", limit: 10)
        #expect(found.count == 1)
        #expect(found.first?.visitCount == 2)
        #expect(found.first?.title == "Swift Blog")
    }

    // AT03 against the real store.
    @Test func expiredEntriesAreRemovedProtectedKept() async throws {
        let repo = try KageDatabase.inMemory().history
        try await repo.recordVisit(visit("https://a.test/1", expiresIn: 60))
        try await repo.recordVisit(visit("https://bank.test/", expiresIn: 60))
        try await repo.recordVisit(visit("https://c.test/", expiresIn: 3600))
        try await repo.setProtected(host: "bank.test", includeSubdomains: true, true)
        let removed = try await repo.deleteExpired(asOf: now.addingTimeInterval(120))
        #expect(removed == 1)
        #expect(try await repo.visits(host: nil, limit: 10).count == 2)
    }

    @Test func ftsInputIsSanitised() async throws {
        let repo = try KageDatabase.inMemory().history
        try await repo.recordVisit(visit("https://x.test/", title: "Hello world"))
        // FTS operators in user input must not throw.
        #expect(try await repo.search("hello\"(*:", limit: 5).count == 1)
        #expect(ftsQuery("  ") == nil)
    }

    // Spec 16: indexed search of 10k history entries under 200 ms.
    @Test func searchTenThousandEntriesIsFast() async throws {
        let db = try KageDatabase.inMemory()
        try await db.store.transaction { s in
            for i in 0..<10_000 {
                try s.execute("INSERT INTO history (id, url, host, title, first_visited_at, last_visited_at) VALUES (?, ?, ?, ?, ?, ?)",
                              [UUID(), "https://site\(i).test/page", "site\(i).test", "Article number \(i) about topic \(i % 97)", 0.0, Double(i)])
            }
        }
        let start = ContinuousClock.now
        let results = try await db.history.search("topic 42", limit: 50)
        let elapsed = ContinuousClock.now - start
        #expect(!results.isEmpty)
        #expect(elapsed < .milliseconds(200))
    }
}

@Suite struct SQLiteLibraryTests {
    @Test func tabsRoundTrip() async throws {
        let repo = try KageDatabase.inMemory().tabs
        let profile = UUID()
        let tab = BrowserTab(url: URL(string: "https://a.test"), title: "A", profileID: profile, state: .suspended,
                             isPinned: true, sortOrder: 3, interactionState: Data([1, 2, 3]))
        try await repo.save([tab])
        let loaded = try await repo.loadAll(profileID: profile)
        #expect(loaded.count == 1)
        #expect(loaded.first?.interactionState == Data([1, 2, 3]))
        #expect(loaded.first?.isPinned == true)
    }

    // AT15: bookmarks work locally with no iCloud.
    @Test func bookmarksAndReadingList() async throws {
        let repo = try KageDatabase.inMemory().bookmarks
        let folder = BookmarkFolder(name: "Work")
        try await repo.saveFolder(folder)
        try await repo.save(Bookmark(url: URL(string: "https://a.test")!, title: "Alpha", folderID: folder.id, tags: ["ref"]))
        let rl = Bookmark(url: URL(string: "https://b.test")!, title: "Beta", isReadingList: true, savedContent: "text")
        try await repo.save(rl)
        #expect(try await repo.all(folderID: folder.id, readingList: nil).count == 1)
        #expect(try await repo.all(folderID: nil, readingList: true).first?.savedContent == "text")
        #expect(try await repo.search("ref").count == 1)
        try await repo.delete(id: rl.id)
        #expect(try await repo.all(folderID: nil, readingList: true).isEmpty)
    }

    @Test func protectedSitesRoundTrip() async throws {
        let repo = try KageDatabase.inMemory().protectedSites
        try await repo.save(ProtectedSite(domain: "github.com", allowedDataTypes: [.cookies, .localStorage]))
        let all = try await repo.all()
        #expect(all.first?.allowedDataTypes == [.cookies, .localStorage])
    }

    @Test func siteSettings() async throws {
        let repo = try KageDatabase.inMemory().siteSettings
        try await repo.set(host: "a.test", key: "camera", value: "allow")
        #expect(try await repo.value(host: "a.test", key: "camera") == "allow")
        try await repo.set(host: "a.test", key: "camera", value: nil)
        #expect(try await repo.value(host: "a.test", key: "camera") == nil)
    }

    @Test func aiSessionsExpire() async throws {
        let repo = try KageDatabase.inMemory().aiSessions
        let past = Date(timeIntervalSince1970: 10)
        try await repo.save(AISession(tabIDs: [UUID()], modelID: "m", expiresAt: past,
                                      localMessages: [.init(role: .user, text: "hi")]))
        try await repo.save(AISession(tabIDs: [], modelID: "m"))
        #expect(try await repo.deleteExpired(asOf: Date(timeIntervalSince1970: 20)) == 1)
        #expect(try await repo.all().count == 1)
    }

    @Test func cleanupLogKeepsLatest() async throws {
        let repo = try KageDatabase.inMemory().cleanupLog
        try await repo.append(.init(ranAt: Date(timeIntervalSince1970: 1), trigger: "launch", complete: true, summary: "a"))
        try await repo.append(.init(ranAt: Date(timeIntervalSince1970: 2), trigger: "manual", complete: false, summary: "b"))
        #expect(try await repo.latest()?.summary == "b")
    }
}

@Suite struct SyncMergeTests {
    @Test func newerRemoteWinsOlderIgnored() {
        let id = UUID()
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
        let local = Bookmark(id: id, url: URL(string: "https://a.test")!, title: "local", modifiedAt: old)
        let remote = Bookmark(id: id, url: URL(string: "https://a.test")!, title: "remote", modifiedAt: new)
        #expect(SyncMerge.merge(local: [local], remote: [remote]).first?.title == "remote")
        #expect(SyncMerge.merge(local: [remote], remote: [local]).first?.title == "remote")
    }
}
