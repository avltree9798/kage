import Foundation
import KageModels

private func json<T: Encodable>(_ v: T) -> String {
    (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
}
private func unjson<T: Decodable>(_ s: String?, as: T.Type) -> T? {
    s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
}

/// Turns free text into a safe FTS5 prefix query: each word quoted, so user input can't inject FTS syntax.
func ftsQuery(_ text: String) -> String? {
    let tokens = text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
}

// MARK: - History

public struct SQLiteHistoryRepository: HistoryRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func recordVisit(_ v: HistoryVisit) async throws {
        try await store.execute("""
            INSERT INTO history (id, url, host, title, first_visited_at, last_visited_at, visit_count, expires_at, is_protected)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET
                last_visited_at = excluded.last_visited_at,
                visit_count = history.visit_count + 1,
                expires_at = excluded.expires_at,
                is_protected = excluded.is_protected,
                title = CASE WHEN excluded.title = '' THEN history.title ELSE excluded.title END
            """, [v.id, v.url, v.url.kageHost, v.title, v.firstVisitedAt, v.lastVisitedAt, v.visitCount, v.expiresAt, v.isProtected])
    }

    public func search(_ query: String, limit: Int) async throws -> [HistoryVisit] {
        guard let fts = ftsQuery(query) else { return try await visits(host: nil, limit: limit) }
        let rows = try await store.query("""
            SELECT h.* FROM history_fts f JOIN history h ON h.rowid = f.rowid
            WHERE history_fts MATCH ? ORDER BY h.last_visited_at DESC LIMIT ?
            """, [fts, limit])
        return rows.compactMap(Self.visit)
    }

    public func visits(host: String?, limit: Int) async throws -> [HistoryVisit] {
        let rows: [SQLRow]
        if let host {
            rows = try await store.query("SELECT * FROM history WHERE host = ? ORDER BY last_visited_at DESC LIMIT ?", [host, limit])
        } else {
            rows = try await store.query("SELECT * FROM history ORDER BY last_visited_at DESC LIMIT ?", [limit])
        }
        return rows.compactMap(Self.visit)
    }

    public func deleteExpired(asOf date: Date) async throws -> Int {
        try await store.executeReturningChanges(
            "DELETE FROM history WHERE is_protected = 0 AND expires_at IS NOT NULL AND expires_at <= ?", [date])
    }

    public func delete(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try await store.execute("DELETE FROM history WHERE id IN (\(marks))", ids)
    }

    public func deleteAll(includingProtected: Bool) async throws -> Int {
        try await store.executeReturningChanges(includingProtected
            ? "DELETE FROM history" : "DELETE FROM history WHERE is_protected = 0")
    }

    public func setProtected(host: String, includeSubdomains: Bool, _ isProtected: Bool) async throws {
        try await store.execute(
            "UPDATE history SET is_protected = ? WHERE host = ? OR (? AND host LIKE ?)",
            [isProtected, host, includeSubdomains, "%." + host])
    }

    static func visit(_ r: SQLRow) -> HistoryVisit? {
        guard let id = r.uuid("id"), let url = r.string("url").flatMap(URL.init(string:)),
              let first = r.date("first_visited_at"), let last = r.date("last_visited_at") else { return nil }
        return HistoryVisit(id: id, url: url, title: r.string("title") ?? "", firstVisitedAt: first,
                            lastVisitedAt: last, visitCount: r.int("visit_count") ?? 1,
                            expiresAt: r.date("expires_at"), isProtected: r.bool("is_protected"))
    }
}

// MARK: - Tabs

public struct SQLiteTabRepository: TabRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func save(_ tabs: [BrowserTab]) async throws {
        try await store.transaction { db in
            for t in tabs {
                try db.execute("""
                    INSERT OR REPLACE INTO tabs (id, url, title, group_id, profile_id, created_at, last_active_at, state,
                        is_protected, is_pinned, sort_order, snapshot_reference, interaction_state)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [t.id, t.url, t.title, t.groupID, t.profileID, t.createdAt, t.lastActiveAt, t.state.rawValue,
                          t.isProtected, t.isPinned, t.sortOrder, t.snapshotReference, t.interactionState])
            }
        }
    }

    public func loadAll(profileID: UUID) async throws -> [BrowserTab] {
        try await store.query("SELECT * FROM tabs WHERE profile_id = ? ORDER BY sort_order", [profileID]).compactMap { r in
            guard let id = r.uuid("id"), let pid = r.uuid("profile_id"), let c = r.date("created_at"),
                  let a = r.date("last_active_at") else { return nil }
            return BrowserTab(id: id, url: r.string("url").flatMap(URL.init(string:)), title: r.string("title") ?? "",
                              groupID: r.uuid("group_id"), profileID: pid, createdAt: c, lastActiveAt: a,
                              state: TabState(rawValue: r.string("state") ?? "") ?? .suspended,
                              isProtected: r.bool("is_protected"), isPinned: r.bool("is_pinned"),
                              sortOrder: r.int("sort_order") ?? 0, snapshotReference: r.string("snapshot_reference"),
                              interactionState: r.data("interaction_state"))
        }
    }

    public func delete(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try await store.execute("DELETE FROM tabs WHERE id IN (\(marks))", ids)
    }

    public func deleteAll(profileID: UUID) async throws {
        try await store.execute("DELETE FROM tabs WHERE profile_id = ?", [profileID])
    }

    public func saveGroups(_ groups: [TabGroup]) async throws {
        try await store.transaction { db in
            for g in groups {
                try db.execute("INSERT OR REPLACE INTO tab_groups (id, name, colour, sort_order, default_profile_id) VALUES (?, ?, ?, ?, ?)",
                               [g.id, g.name, g.colour, g.sortOrder, g.defaultProfileID])
            }
        }
    }

    public func loadGroups() async throws -> [TabGroup] {
        try await store.query("SELECT * FROM tab_groups ORDER BY sort_order").compactMap { r in
            guard let id = r.uuid("id") else { return nil }
            return TabGroup(id: id, name: r.string("name") ?? "", colour: r.string("colour") ?? "graphite",
                            sortOrder: r.int("sort_order") ?? 0, defaultProfileID: r.uuid("default_profile_id"))
        }
    }
}

// MARK: - Bookmarks

public struct SQLiteBookmarkRepository: BookmarkRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func save(_ b: Bookmark) async throws {
        try await store.execute("""
            INSERT OR REPLACE INTO bookmarks (id, url, title, folder_id, tags, is_favourite, is_reading_list, is_read,
                saved_content, created_at, modified_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """, [b.id, b.url, b.title, b.folderID, b.tags.joined(separator: ","), b.isFavourite, b.isReadingList,
                  b.isRead, b.savedContent, b.createdAt, b.modifiedAt])
    }

    /// Soft delete keeps a tombstone for optional sync merge rules (risk register: sync conflicts).
    public func delete(id: UUID) async throws {
        try await store.execute("UPDATE bookmarks SET deleted_at = ?, saved_content = NULL WHERE id = ?", [Date(), id])
    }

    public func all(folderID: UUID?, readingList: Bool?) async throws -> [Bookmark] {
        var sql = "SELECT * FROM bookmarks WHERE deleted_at IS NULL"
        var args: [SQLBindable] = []
        if let folderID { sql += " AND folder_id = ?"; args.append(folderID) }
        if let readingList { sql += " AND is_reading_list = ?"; args.append(readingList) }
        sql += " ORDER BY created_at DESC"
        return try await store.query(sql, args).compactMap(Self.bookmark)
    }

    public func search(_ text: String) async throws -> [Bookmark] {
        let like = "%" + text.replacingOccurrences(of: "%", with: "") + "%"
        return try await store.query("""
            SELECT * FROM bookmarks WHERE deleted_at IS NULL AND (title LIKE ? OR url LIKE ? OR tags LIKE ?)
            ORDER BY created_at DESC
            """, [like, like, like]).compactMap(Self.bookmark)
    }

    public func saveFolder(_ f: BookmarkFolder) async throws {
        try await store.execute("INSERT OR REPLACE INTO bookmark_folders (id, name, parent_id, sort_order) VALUES (?, ?, ?, ?)",
                                [f.id, f.name, f.parentID, f.sortOrder])
    }

    public func folders() async throws -> [BookmarkFolder] {
        try await store.query("SELECT * FROM bookmark_folders ORDER BY sort_order").compactMap { r in
            guard let id = r.uuid("id") else { return nil }
            return BookmarkFolder(id: id, name: r.string("name") ?? "", parentID: r.uuid("parent_id"), sortOrder: r.int("sort_order") ?? 0)
        }
    }

    static func bookmark(_ r: SQLRow) -> Bookmark? {
        guard let id = r.uuid("id"), let url = r.string("url").flatMap(URL.init(string:)) else { return nil }
        let tags = (r.string("tags") ?? "").split(separator: ",").map(String.init)
        return Bookmark(id: id, url: url, title: r.string("title") ?? "", folderID: r.uuid("folder_id"), tags: tags,
                        isFavourite: r.bool("is_favourite"), isReadingList: r.bool("is_reading_list"),
                        isRead: r.bool("is_read"), savedContent: r.string("saved_content"),
                        createdAt: r.date("created_at") ?? .now, modifiedAt: r.date("modified_at") ?? .now)
    }
}

// MARK: - Protected sites, site settings, downloads, AI, cleanup log

public struct SQLiteProtectedSiteRepository: ProtectedSiteRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func all() async throws -> [ProtectedSite] {
        try await store.query("SELECT * FROM protected_sites ORDER BY domain").compactMap { r in
            guard let id = r.uuid("id"), let domain = r.string("domain") else { return nil }
            let kinds = Set((r.string("allowed_data_types") ?? "").split(separator: ",").compactMap { WebsiteDataKind(rawValue: String($0)) })
            return ProtectedSite(id: id, domain: domain, includeSubdomains: r.bool("include_subdomains"),
                                 allowedDataTypes: kinds, createdAt: r.date("created_at") ?? .now, notes: r.string("notes"))
        }
    }

    public func save(_ s: ProtectedSite) async throws {
        try await store.execute("""
            INSERT INTO protected_sites (id, domain, include_subdomains, allowed_data_types, created_at, notes)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(domain) DO UPDATE SET include_subdomains = excluded.include_subdomains,
                allowed_data_types = excluded.allowed_data_types, notes = excluded.notes
            """, [s.id, s.domain, s.includeSubdomains, s.allowedDataTypes.map(\.rawValue).sorted().joined(separator: ","),
                  s.createdAt, s.notes])
    }

    public func delete(id: UUID) async throws {
        try await store.execute("DELETE FROM protected_sites WHERE id = ?", [id])
    }
}

public struct SQLiteSiteSettingsRepository: SiteSettingsRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func value(host: String, key: String) async throws -> String? {
        try await store.query("SELECT value FROM site_settings WHERE host = ? AND key = ?", [host, key]).first?.string("value")
    }

    public func set(host: String, key: String, value: String?) async throws {
        if let value {
            try await store.execute("INSERT OR REPLACE INTO site_settings (host, key, value) VALUES (?, ?, ?)", [host, key, value])
        } else {
            try await store.execute("DELETE FROM site_settings WHERE host = ? AND key = ?", [host, key])
        }
    }

    public func all(host: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        for r in try await store.query("SELECT key, value FROM site_settings WHERE host = ?", [host]) {
            if let k = r.string("key"), let v = r.string("value") { out[k] = v }
        }
        return out
    }

    public func deleteAll() async throws { try await store.execute("DELETE FROM site_settings") }
}

public struct SQLiteDownloadRepository: DownloadRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func save(_ d: DownloadRecord, resumeData: Data?) async throws {
        try await store.execute("""
            INSERT OR REPLACE INTO downloads (id, source_url, filename, destination_bookmark, status, progress, resume_data, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [d.id, d.sourceURL, d.filename, d.destinationBookmark, d.status.rawValue, d.progress, resumeData, d.createdAt])
    }

    public func all() async throws -> [DownloadRecord] {
        try await store.query("SELECT * FROM downloads ORDER BY created_at DESC").compactMap { r in
            guard let id = r.uuid("id"), let url = r.string("source_url").flatMap(URL.init(string:)) else { return nil }
            return DownloadRecord(id: id, sourceURL: url, filename: r.string("filename") ?? "download",
                                  destinationBookmark: r.data("destination_bookmark"),
                                  status: DownloadRecord.Status(rawValue: r.string("status") ?? "") ?? .failed,
                                  progress: r.double("progress"), createdAt: r.date("created_at") ?? .now)
        }
    }

    public func resumeData(id: UUID) async throws -> Data? {
        try await store.query("SELECT resume_data FROM downloads WHERE id = ?", [id]).first?.data("resume_data")
    }

    public func delete(id: UUID) async throws { try await store.execute("DELETE FROM downloads WHERE id = ?", [id]) }
}

public struct SQLiteAISessionRepository: AISessionRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func save(_ s: AISession) async throws {
        try await store.execute("""
            INSERT OR REPLACE INTO ai_sessions (id, tab_ids, model_id, created_at, expires_at, messages, source_references)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [s.id, json(s.tabIDs), s.modelID, s.createdAt, s.expiresAt, json(s.localMessages), json(s.sourceReferences)])
    }

    public func all() async throws -> [AISession] {
        try await store.query("SELECT * FROM ai_sessions ORDER BY created_at DESC").compactMap { r in
            guard let id = r.uuid("id") else { return nil }
            return AISession(id: id, tabIDs: unjson(r.string("tab_ids"), as: [UUID].self) ?? [],
                             modelID: r.string("model_id") ?? "", createdAt: r.date("created_at") ?? .now,
                             expiresAt: r.date("expires_at"),
                             localMessages: unjson(r.string("messages"), as: [AISession.Message].self) ?? [],
                             sourceReferences: unjson(r.string("source_references"), as: [URL].self) ?? [])
        }
    }

    public func deleteExpired(asOf date: Date) async throws -> Int {
        try await store.executeReturningChanges("DELETE FROM ai_sessions WHERE expires_at IS NOT NULL AND expires_at <= ?", [date])
    }

    public func deleteAll() async throws {
        try await store.execute("DELETE FROM research_notes")
        try await store.execute("DELETE FROM ai_sessions")
    }

    public func saveNote(_ n: ResearchNote) async throws {
        try await store.execute("INSERT OR REPLACE INTO research_notes (id, session_id, text, source_url, created_at) VALUES (?, ?, ?, ?, ?)",
                                [n.id, n.sessionID, n.text, n.sourceURL, n.createdAt])
    }

    public func notes(sessionID: UUID?) async throws -> [ResearchNote] {
        let rows: [SQLRow]
        if let sessionID {
            rows = try await store.query("SELECT * FROM research_notes WHERE session_id = ? ORDER BY created_at", [sessionID])
        } else {
            rows = try await store.query("SELECT * FROM research_notes ORDER BY created_at")
        }
        return rows.compactMap { r in
            guard let id = r.uuid("id") else { return nil }
            return ResearchNote(id: id, sessionID: r.uuid("session_id"), text: r.string("text") ?? "",
                                sourceURL: r.string("source_url").flatMap(URL.init(string:)), createdAt: r.date("created_at") ?? .now)
        }
    }
}

public struct SQLiteCleanupLogRepository: CleanupLogRepository {
    let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func append(_ e: CleanupLogEntry) async throws {
        try await store.execute("INSERT INTO cleanup_log (ran_at, trigger, complete, summary) VALUES (?, ?, ?, ?)",
                                [e.ranAt, e.trigger, e.complete, e.summary])
        try await store.execute("DELETE FROM cleanup_log WHERE id NOT IN (SELECT id FROM cleanup_log ORDER BY id DESC LIMIT 50)")
    }

    public func latest() async throws -> CleanupLogEntry? {
        guard let r = try await store.query("SELECT * FROM cleanup_log ORDER BY id DESC LIMIT 1").first else { return nil }
        return CleanupLogEntry(ranAt: r.date("ran_at") ?? .now, trigger: r.string("trigger") ?? "",
                               complete: r.bool("complete"), summary: r.string("summary") ?? "")
    }
}

/// Every repository over one store, for dependency injection.
public struct KageDatabase: Sendable {
    public let store: SQLiteStore
    public let history: SQLiteHistoryRepository
    public let tabs: SQLiteTabRepository
    public let bookmarks: SQLiteBookmarkRepository
    public let protectedSites: SQLiteProtectedSiteRepository
    public let siteSettings: SQLiteSiteSettingsRepository
    public let downloads: SQLiteDownloadRepository
    public let aiSessions: SQLiteAISessionRepository
    public let cleanupLog: SQLiteCleanupLogRepository

    public init(store: SQLiteStore) {
        self.store = store
        history = .init(store: store); tabs = .init(store: store); bookmarks = .init(store: store)
        protectedSites = .init(store: store); siteSettings = .init(store: store); downloads = .init(store: store)
        aiSessions = .init(store: store); cleanupLog = .init(store: store)
    }

    public static func inMemory() throws -> KageDatabase { try KageDatabase(store: SQLiteStore(path: ":memory:")) }
}
