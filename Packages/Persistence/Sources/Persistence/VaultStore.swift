#if canImport(CryptoKit)
import Foundation
import CryptoKit
import KageModels

/// Hands out the Vault data key. It throws while the Vault is locked (threat model T-10).
public typealias VaultKeySource = @Sendable () async throws -> SymmetricKey

/// Sealed records for the Vault profile, in their own database file (threat model T-10).
///
/// Every row is AES-256-GCM sealed with a key that exists only while the Vault is unlocked.
/// Row ids are an HMAC of the record's natural key, so the file shows neither the URL nor
/// the tab id. The kind and id are authenticated with each row, so rows can't be swapped.
/// Plaintext exists only in memory, only for the duration of a call.
public actor VaultSealedStore {
    public enum Kind: String, Sendable { case history, tab, tabGroup }

    public static let migrations = [
        Migration(version: 1, sql: """
            CREATE TABLE vault_records (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                sealed BLOB NOT NULL,
                PRIMARY KEY (kind, id)
            ) WITHOUT ROWID;
            """),
    ]

    public let store: SQLiteStore
    private let keySource: VaultKeySource

    public init(store: SQLiteStore, key: @escaping VaultKeySource) {
        self.store = store; self.keySource = key
    }

    public static func inMemory(key: @escaping VaultKeySource) throws -> VaultSealedStore {
        VaultSealedStore(store: try SQLiteStore(path: ":memory:", migrations: migrations), key: key)
    }

    public static func openDefault(key: @escaping VaultKeySource) throws -> VaultSealedStore {
        VaultSealedStore(store: try SQLiteStore.openDefault(name: "Vault.sqlite", migrations: migrations), key: key)
    }

    struct Keys {
        let seal: SymmetricKey
        let index: SymmetricKey
    }

    private func keys() async throws -> Keys {
        let master = try await keySource()
        return Keys(
            seal: HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("kage.vault.seal.v1".utf8), outputByteCount: 32),
            index: HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("kage.vault.index.v1".utf8), outputByteCount: 32))
    }

    static func rowID(_ naturalKey: String, kind: Kind, keys: Keys) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(kind.rawValue)|\(naturalKey)".utf8), using: keys.index)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private static func aad(_ kind: Kind, _ id: String) -> Data { Data("\(kind.rawValue)|\(id)".utf8) }

    /// Seals and stores `values`, keyed by `naturalKey`. Throws while locked.
    public func put<T: Encodable & Sendable>(_ values: [(naturalKey: String, value: T)], kind: Kind) async throws {
        let k = try await keys()
        var rows: [(String, Data)] = []
        for item in values {
            var plain = try JSONEncoder().encode(item.value)
            defer { plain.resetBytes(in: 0..<plain.count) }
            let id = Self.rowID(item.naturalKey, kind: kind, keys: k)
            guard let sealed = try AES.GCM.seal(plain, using: k.seal, authenticating: Self.aad(kind, id)).combined else {
                throw CryptoKitError.incorrectParameterSize
            }
            rows.append((id, sealed))
        }
        let kindName = kind.rawValue
        let sealedRows = rows
        try await store.transaction { db in
            for (id, sealed) in sealedRows {
                try db.execute("INSERT OR REPLACE INTO vault_records (kind, id, sealed) VALUES (?, ?, ?)", [kindName, id, sealed])
            }
        }
    }

    public func get<T: Decodable & Sendable>(_ naturalKey: String, kind: Kind, as type: T.Type) async throws -> T? {
        let k = try await keys()
        let id = Self.rowID(naturalKey, kind: kind, keys: k)
        guard let row = try await store.query("SELECT sealed FROM vault_records WHERE kind = ? AND id = ?", [kind.rawValue, id]).first,
              let sealed = row.data("sealed") else { return nil }
        return try Self.open(sealed, kind: kind, id: id, keys: k, as: type)
    }

    /// Opens every record of `kind`. A row that fails authentication is skipped, never trusted.
    public func all<T: Decodable & Sendable>(kind: Kind, as type: T.Type) async throws -> [T] {
        let k = try await keys()
        return try await store.query("SELECT id, sealed FROM vault_records WHERE kind = ?", [kind.rawValue]).compactMap { r in
            guard let id = r.string("id"), let sealed = r.data("sealed") else { return nil }
            return try? Self.open(sealed, kind: kind, id: id, keys: k, as: type)
        }
    }

    public func delete(_ naturalKeys: [String], kind: Kind) async throws {
        guard !naturalKeys.isEmpty else { return }
        let k = try await keys()
        let ids = naturalKeys.map { Self.rowID($0, kind: kind, keys: k) }
        let kindName = kind.rawValue
        try await store.transaction { db in
            for id in ids { try db.execute("DELETE FROM vault_records WHERE kind = ? AND id = ?", [kindName, id]) }
        }
    }

    /// Works while locked: deleting needs no key.
    @discardableResult
    public func deleteAll(kind: Kind) async throws -> Int {
        try await store.executeReturningChanges("DELETE FROM vault_records WHERE kind = ?", [kind.rawValue])
    }

    public func count(kind: Kind) async throws -> Int {
        try await store.query("SELECT COUNT(*) AS n FROM vault_records WHERE kind = ?", [kind.rawValue]).first?.int("n") ?? 0
    }

    private static func open<T: Decodable>(_ sealed: Data, kind: Kind, id: String, keys: Keys, as: T.Type) throws -> T {
        let box = try AES.GCM.SealedBox(combined: sealed)
        var plain = try AES.GCM.open(box, using: keys.seal, authenticating: aad(kind, id))
        defer { plain.resetBytes(in: 0..<plain.count) }
        return try JSONDecoder().decode(T.self, from: plain)
    }
}

// MARK: - Repositories

/// Vault history: sealed, deduplicated by URL, searched in memory after decryption.
public struct VaultHistoryRepository: HistoryRepository {
    let vault: VaultSealedStore
    public init(vault: VaultSealedStore) { self.vault = vault }

    public func recordVisit(_ visit: HistoryVisit) async throws {
        let key = visit.url.absoluteString
        var merged = visit
        if let existing = try await vault.get(key, kind: .history, as: HistoryVisit.self) {
            merged = existing
            merged.lastVisitedAt = visit.lastVisitedAt
            merged.visitCount += 1
            merged.expiresAt = visit.expiresAt
            if !visit.title.isEmpty { merged.title = visit.title }
        }
        try await vault.put([(naturalKey: key, value: merged)], kind: .history)
    }

    private func everything() async throws -> [HistoryVisit] {
        try await vault.all(kind: .history, as: HistoryVisit.self).sorted { $0.lastVisitedAt > $1.lastVisitedAt }
    }

    public func search(_ query: String, limit: Int) async throws -> [HistoryVisit] {
        let q = query.lowercased()
        return Array(try await everything().filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }.prefix(limit))
    }

    public func visits(host: String?, limit: Int) async throws -> [HistoryVisit] {
        Array(try await everything().filter { host == nil || $0.url.kageHost == host }.prefix(limit))
    }

    public func deleteExpired(asOf date: Date) async throws -> Int {
        let doomed = try await everything().filter { v in
            guard !v.isProtected, let e = v.expiresAt else { return false }
            return e <= date
        }
        try await vault.delete(doomed.map(\.url.absoluteString), kind: .history)
        return doomed.count
    }

    public func delete(ids: [UUID]) async throws {
        let wanted = Set(ids)
        let doomed = try await everything().filter { wanted.contains($0.id) }
        try await vault.delete(doomed.map(\.url.absoluteString), kind: .history)
    }

    public func deleteAll(includingProtected: Bool) async throws -> Int {
        if includingProtected { return try await vault.deleteAll(kind: .history) }
        let doomed = try await everything().filter { !$0.isProtected }
        try await vault.delete(doomed.map(\.url.absoluteString), kind: .history)
        return doomed.count
    }

    public func setProtected(host: String, includeSubdomains: Bool, _ isProtected: Bool) async throws {
        let changed = try await everything().compactMap { v -> (naturalKey: String, value: HistoryVisit)? in
            let h = v.url.kageHost
            guard h == host || (includeSubdomains && h.hasSuffix("." + host)) else { return nil }
            var c = v; c.isProtected = isProtected
            return (naturalKey: v.url.absoluteString, value: c)
        }
        try await vault.put(changed, kind: .history)
    }
}

/// Vault tabs: URL, title and back/forward state sealed per tab.
public struct VaultTabRepository: TabRepository {
    let vault: VaultSealedStore
    public init(vault: VaultSealedStore) { self.vault = vault }

    public func save(_ tabs: [BrowserTab]) async throws {
        try await vault.put(tabs.map { (naturalKey: $0.id.uuidString, value: $0) }, kind: .tab)
    }

    public func loadAll(profileID: UUID) async throws -> [BrowserTab] {
        try await vault.all(kind: .tab, as: BrowserTab.self)
            .filter { $0.profileID == profileID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    public func delete(ids: [UUID]) async throws {
        try await vault.delete(ids.map(\.uuidString), kind: .tab)
    }

    public func deleteAll(profileID: UUID) async throws {
        _ = try await vault.deleteAll(kind: .tab)
    }

    public func saveGroups(_ groups: [TabGroup]) async throws {
        try await vault.put(groups.map { (naturalKey: $0.id.uuidString, value: $0) }, kind: .tabGroup)
    }

    public func loadGroups() async throws -> [TabGroup] {
        try await vault.all(kind: .tabGroup, as: TabGroup.self).sorted { $0.sortOrder < $1.sortOrder }
    }
}
#endif
