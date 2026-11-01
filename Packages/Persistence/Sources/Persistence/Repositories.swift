import Foundation
import KageModels

/// Kage-owned history (spec 6.4, ADR-002). Separate from WebKit website data.
public protocol HistoryRepository: Sendable {
    func recordVisit(_ visit: HistoryVisit) async throws
    /// Production implementation uses SQLite FTS5; target < 200 ms at 10k rows (spec 16).
    func search(_ query: String, limit: Int) async throws -> [HistoryVisit]
    /// Removes every non-protected visit whose `expiresAt` is at or before `date`. Returns the count removed.
    func deleteExpired(asOf date: Date) async throws -> Int
    func delete(ids: [UUID]) async throws
    func deleteAll() async throws
}

public protocol TabRepository: Sendable {
    func save(_ tabs: [BrowserTab]) async throws
    func loadAll(profileID: UUID) async throws -> [BrowserTab]
}

/// Reference implementation used by tests and previews until the SQLite store lands (ticket K-04).
public actor InMemoryHistoryRepository: HistoryRepository {
    private var visits: [UUID: HistoryVisit] = [:]

    public init(_ initial: [HistoryVisit] = []) {
        for v in initial { visits[v.id] = v }
    }

    public func recordVisit(_ visit: HistoryVisit) {
        if var existing = visits.values.first(where: { $0.url == visit.url }) {
            existing.lastVisitedAt = visit.lastVisitedAt
            existing.visitCount += 1
            existing.expiresAt = visit.expiresAt
            existing.title = visit.title.isEmpty ? existing.title : visit.title
            visits[existing.id] = existing
        } else {
            visits[visit.id] = visit
        }
    }

    public func search(_ query: String, limit: Int) -> [HistoryVisit] {
        let q = query.lowercased()
        return visits.values
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q) }
            .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
            .prefix(limit)
            .map { $0 }
    }

    public func deleteExpired(asOf date: Date) -> Int {
        let expired = visits.values.filter { v in
            guard !v.isProtected, let e = v.expiresAt else { return false }
            return e <= date
        }
        for v in expired { visits[v.id] = nil }
        return expired.count
    }

    public func delete(ids: [UUID]) { for id in ids { visits[id] = nil } }
    public func deleteAll() { visits.removeAll() }
    public var count: Int { visits.count }
}
