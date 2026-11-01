import Foundation
import Testing
import KageModels
@testable import Persistence

@Suite struct InMemoryHistoryRepositoryTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func visit(_ s: String, expiresIn seconds: TimeInterval?, protected: Bool = false) -> HistoryVisit {
        HistoryVisit(url: URL(string: s)!, firstVisitedAt: now, lastVisitedAt: now,
                     expiresAt: seconds.map { now.addingTimeInterval($0) }, isProtected: protected)
    }

    // AT03: eligible entries are removed at the next permitted cleanup.
    @Test func deleteExpiredRemovesOnlyEligibleEntries() async throws {
        let repo = InMemoryHistoryRepository([
            visit("https://a.test", expiresIn: 60),
            visit("https://b.test", expiresIn: 600),
            visit("https://c.test", expiresIn: 60, protected: true),
            visit("https://d.test", expiresIn: nil),
        ])
        let removed = try await repo.deleteExpired(asOf: now.addingTimeInterval(120))
        #expect(removed == 1)
        #expect(await repo.count == 3)
    }

    @Test func repeatVisitIncrementsCount() async throws {
        let repo = InMemoryHistoryRepository()
        try await repo.recordVisit(visit("https://a.test", expiresIn: 60))
        try await repo.recordVisit(visit("https://a.test", expiresIn: 120))
        let results = try await repo.search("a.test", limit: 10)
        #expect(results.count == 1)
        #expect(results.first?.visitCount == 2)
    }
}
