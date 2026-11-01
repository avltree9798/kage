#if canImport(CryptoKit)
import Foundation
import CryptoKit
import Testing
import KageModels
@testable import Persistence

/// A key gate the tests can lock, standing in for the Secure Enclave.
final class TestVaultKey: @unchecked Sendable {
    private let lock = NSLock()
    private var unlocked = true
    let key: SymmetricKey
    init(_ key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    struct Locked: Error {}
    func setUnlocked(_ v: Bool) { lock.lock(); unlocked = v; lock.unlock() }
    var source: VaultKeySource {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            guard unlocked else { throw Locked() }
            return key
        }
    }
}

@Suite struct VaultStoreTests {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let profile = UUID()

    func visit(_ s: String, title: String = "") -> HistoryVisit {
        HistoryVisit(url: URL(string: s)!, title: title, firstVisitedAt: now, lastVisitedAt: now, expiresAt: nil)
    }

    @Test func historyRoundTripsAndDeduplicates() async throws {
        let key = TestVaultKey()
        let repo = VaultHistoryRepository(vault: try .inMemory(key: key.source))
        try await repo.recordVisit(visit("https://bank.test/account", title: "Account"))
        try await repo.recordVisit(visit("https://bank.test/account"))
        try await repo.recordVisit(visit("https://clinic.test/results", title: "Results"))
        let all = try await repo.visits(host: nil, limit: 10)
        #expect(all.count == 2)
        #expect(all.first { $0.url.kageHost == "bank.test" }?.visitCount == 2)
        #expect(all.first { $0.url.kageHost == "bank.test" }?.title == "Account")
        #expect(try await repo.search("results", limit: 10).map(\.title) == ["Results"])
        try await repo.delete(ids: [all.first { $0.url.kageHost == "clinic.test" }!.id])
        #expect(try await repo.visits(host: nil, limit: 10).count == 1)
    }

    @Test func lockedVaultRefusesReadsAndWritesButStillDeletes() async throws {
        let key = TestVaultKey()
        let repo = VaultHistoryRepository(vault: try .inMemory(key: key.source))
        try await repo.recordVisit(visit("https://a.test"))
        key.setUnlocked(false)
        await #expect(throws: TestVaultKey.Locked.self) { try await repo.visits(host: nil, limit: 10) }
        await #expect(throws: TestVaultKey.Locked.self) { try await repo.recordVisit(visit("https://b.test")) }
        #expect(try await repo.deleteAll(includingProtected: true) == 1)
    }

    @Test func wrongKeyReadsNothing() async throws {
        let store = try SQLiteStore(path: ":memory:", migrations: VaultSealedStore.migrations)
        let right = TestVaultKey()
        try await VaultHistoryRepository(vault: VaultSealedStore(store: store, key: right.source)).recordVisit(visit("https://a.test"))
        let wrong = TestVaultKey()
        let other = VaultHistoryRepository(vault: VaultSealedStore(store: store, key: wrong.source))
        #expect(try await other.visits(host: nil, limit: 10).isEmpty)
    }

    @Test func swappedRowsFailAuthentication() async throws {
        let store = try SQLiteStore(path: ":memory:", migrations: VaultSealedStore.migrations)
        let key = TestVaultKey()
        let vault = VaultSealedStore(store: store, key: key.source)
        let repo = VaultHistoryRepository(vault: vault)
        try await repo.recordVisit(visit("https://a.test", title: "A"))
        try await repo.recordVisit(visit("https://b.test", title: "B"))
        let rows = try await store.query("SELECT id, sealed FROM vault_records ORDER BY id")
        let a = try #require(rows.first?.data("sealed")), b = try #require(rows.last?.data("sealed"))
        try await store.execute("UPDATE vault_records SET sealed = ? WHERE id = ?", [b, rows.first!.string("id")!])
        try await store.execute("UPDATE vault_records SET sealed = ? WHERE id = ?", [a, rows.last!.string("id")!])
        #expect(try await repo.visits(host: nil, limit: 10).isEmpty)
    }

    @Test func tabsRoundTrip() async throws {
        let key = TestVaultKey()
        let repo = VaultTabRepository(vault: try .inMemory(key: key.source))
        let t1 = BrowserTab(url: URL(string: "https://a.test"), title: "A", profileID: profile, sortOrder: 1)
        let t0 = BrowserTab(url: URL(string: "https://b.test"), title: "B", profileID: profile, sortOrder: 0,
                            interactionState: Data([1, 2, 3]))
        try await repo.save([t1, t0])
        #expect(try await repo.loadAll(profileID: profile).map(\.title) == ["B", "A"])
        #expect(try await repo.loadAll(profileID: profile).first?.interactionState == Data([1, 2, 3]))
        try await repo.delete(ids: [t1.id])
        #expect(try await repo.loadAll(profileID: profile).count == 1)
    }

    /// The file on disk must not contain any URL, host, title or tab id in the clear.
    @Test func nothingReadableOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Vault.sqlite").path
        let key = TestVaultKey()
        let tab = BrowserTab(url: URL(string: "https://secret-clinic.test/tab"), title: "Tab title marker", profileID: profile)
        do {
            let vault = VaultSealedStore(store: try SQLiteStore(path: path, migrations: VaultSealedStore.migrations), key: key.source)
            try await VaultHistoryRepository(vault: vault).recordVisit(visit("https://secret-clinic.test/results", title: "Lab results marker"))
            try await VaultTabRepository(vault: vault).save([tab])
            try await vault.store.execute("PRAGMA wal_checkpoint(FULL)")
        }
        var bytes = Data()
        for suffix in ["", "-wal", "-shm"] {
            if let d = FileManager.default.contents(atPath: path + suffix) { bytes.append(d) }
        }
        #expect(!bytes.isEmpty)
        for needle in ["secret-clinic", "Lab results marker", "Tab title marker", tab.id.uuidString] {
            #expect(bytes.range(of: Data(needle.utf8)) == nil, "found \(needle) in the clear")
        }
    }
}
#endif
