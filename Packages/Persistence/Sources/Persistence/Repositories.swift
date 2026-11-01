import Foundation
import KageModels

/// Kage-owned history (spec 6.4, ADR-002). Separate from WebKit website data.
public protocol HistoryRepository: Sendable {
    func recordVisit(_ visit: HistoryVisit) async throws
    /// SQLite FTS5 in production; target < 200 ms at 10k rows (spec 16).
    func search(_ query: String, limit: Int) async throws -> [HistoryVisit]
    func visits(host: String?, limit: Int) async throws -> [HistoryVisit]
    /// Removes every non-protected visit whose `expiresAt` is at or before `date`. Returns the count removed.
    func deleteExpired(asOf date: Date) async throws -> Int
    func delete(ids: [UUID]) async throws
    func deleteAll(includingProtected: Bool) async throws -> Int
    func setProtected(host: String, includeSubdomains: Bool, _ isProtected: Bool) async throws
}

public extension HistoryRepository {
    func deleteAll() async throws { _ = try await deleteAll(includingProtected: true) }
}

public protocol TabRepository: Sendable {
    func save(_ tabs: [BrowserTab]) async throws
    func loadAll(profileID: UUID) async throws -> [BrowserTab]
    func delete(ids: [UUID]) async throws
    func deleteAll(profileID: UUID) async throws
    func saveGroups(_ groups: [TabGroup]) async throws
    func loadGroups() async throws -> [TabGroup]
}

public protocol BookmarkRepository: Sendable {
    func save(_ bookmark: Bookmark) async throws
    func delete(id: UUID) async throws
    func all(folderID: UUID?, readingList: Bool?) async throws -> [Bookmark]
    func search(_ text: String) async throws -> [Bookmark]
    func saveFolder(_ folder: BookmarkFolder) async throws
    func folders() async throws -> [BookmarkFolder]
}

public protocol ProtectedSiteRepository: Sendable {
    func all() async throws -> [ProtectedSite]
    func save(_ site: ProtectedSite) async throws
    func delete(id: UUID) async throws
}

public protocol SiteSettingsRepository: Sendable {
    func value(host: String, key: String) async throws -> String?
    func set(host: String, key: String, value: String?) async throws
    func all(host: String) async throws -> [String: String]
    func deleteAll() async throws
}

public protocol DownloadRepository: Sendable {
    func save(_ record: DownloadRecord, resumeData: Data?) async throws
    func all() async throws -> [DownloadRecord]
    func resumeData(id: UUID) async throws -> Data?
    func delete(id: UUID) async throws
}

public protocol AISessionRepository: Sendable {
    func save(_ session: AISession) async throws
    func all() async throws -> [AISession]
    func deleteExpired(asOf date: Date) async throws -> Int
    func deleteAll() async throws
    func saveNote(_ note: ResearchNote) async throws
    func notes(sessionID: UUID?) async throws -> [ResearchNote]
}

public struct CleanupLogEntry: Sendable, Equatable {
    public var ranAt: Date
    public var trigger: String
    public var complete: Bool
    public var summary: String
    public init(ranAt: Date, trigger: String, complete: Bool, summary: String) {
        self.ranAt = ranAt; self.trigger = trigger; self.complete = complete; self.summary = summary
    }
}

public protocol CleanupLogRepository: Sendable {
    func append(_ entry: CleanupLogEntry) async throws
    func latest() async throws -> CleanupLogEntry?
}

// MARK: - In-memory reference implementation

/// Used by tests and previews.
public actor InMemoryHistoryRepository: HistoryRepository {
    private var visitsByID: [UUID: HistoryVisit] = [:]

    public init(_ initial: [HistoryVisit] = []) {
        for v in initial { visitsByID[v.id] = v }
    }

    public func recordVisit(_ visit: HistoryVisit) {
        if var existing = visitsByID.values.first(where: { $0.url == visit.url }) {
            existing.lastVisitedAt = visit.lastVisitedAt
            existing.visitCount += 1
            existing.expiresAt = visit.expiresAt
            existing.title = visit.title.isEmpty ? existing.title : visit.title
            visitsByID[existing.id] = existing
        } else {
            visitsByID[visit.id] = visit
        }
    }

    public func search(_ query: String, limit: Int) -> [HistoryVisit] {
        let q = query.lowercased()
        return visitsByID.values
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q) }
            .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
            .prefix(limit)
            .map { $0 }
    }

    public func visits(host: String?, limit: Int) -> [HistoryVisit] {
        visitsByID.values
            .filter { host == nil || $0.url.kageHost == host }
            .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
            .prefix(limit).map { $0 }
    }

    public func deleteExpired(asOf date: Date) -> Int {
        let expired = visitsByID.values.filter { v in
            guard !v.isProtected, let e = v.expiresAt else { return false }
            return e <= date
        }
        for v in expired { visitsByID[v.id] = nil }
        return expired.count
    }

    public func delete(ids: [UUID]) { for id in ids { visitsByID[id] = nil } }

    public func deleteAll(includingProtected: Bool) -> Int {
        let doomed = visitsByID.values.filter { includingProtected || !$0.isProtected }
        for v in doomed { visitsByID[v.id] = nil }
        return doomed.count
    }

    public func setProtected(host: String, includeSubdomains: Bool, _ isProtected: Bool) {
        for (id, v) in visitsByID {
            let h = v.url.kageHost
            if h == host || (includeSubdomains && h.hasSuffix("." + host)) {
                visitsByID[id]?.isProtected = isProtected
            }
        }
    }

    public var count: Int { visitsByID.count }
}
