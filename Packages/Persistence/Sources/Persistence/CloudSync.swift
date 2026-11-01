import Foundation
import KageModels

/// Optional iCloud sync for bookmarks and the reading list (spec 6.5, 12, ADR-009).
/// Private sessions, history, protected-site metadata and AI chats are never synced (spec 14.8).
public protocol CloudSyncing: Sendable {
    func push(_ bookmarks: [Bookmark]) async throws
    func pull() async throws -> [Bookmark]
}

/// Last-writer-wins merge on `modifiedAt`, keyed by stable bookmark ID.
public enum SyncMerge {
    public static func merge(local: [Bookmark], remote: [Bookmark]) -> [Bookmark] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in remote {
            if let l = byID[r.id], l.modifiedAt >= r.modifiedAt { continue }
            byID[r.id] = r
        }
        return byID.values.sorted { $0.createdAt > $1.createdAt }
    }
}

#if canImport(CloudKit)
import CloudKit

/// CloudKit adapter. Fields that identify what you read are stored in `encryptedValues`,
/// which CloudKit encrypts end to end with keys in the user's iCloud Keychain (spec 24 Q7).
/// Requires an iCloud container entitlement; the app only creates this when one is configured.
public struct CloudKitBookmarkSync: CloudSyncing {
    let containerID: String
    static let recordType = "Bookmark"

    public init(containerID: String) { self.containerID = containerID }

    /// Reads the container ID from Info.plist (`KageCloudKitContainer`). Nil means sync isn't set up in this build.
    public static func fromBundle(_ bundle: Bundle = .main) -> CloudKitBookmarkSync? {
        (bundle.object(forInfoDictionaryKey: "KageCloudKitContainer") as? String).map(CloudKitBookmarkSync.init)
    }

    private var database: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }

    public func push(_ bookmarks: [Bookmark]) async throws {
        let records = bookmarks.map { b -> CKRecord in
            let r = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: b.id.uuidString))
            r.encryptedValues["url"] = b.url.absoluteString
            r.encryptedValues["title"] = b.title
            r.encryptedValues["tags"] = b.tags.joined(separator: ",")
            r["isFavourite"] = b.isFavourite ? 1 : 0
            r["isReadingList"] = b.isReadingList ? 1 : 0
            r["isRead"] = b.isRead ? 1 : 0
            r["createdAt"] = b.createdAt
            r["modifiedAt"] = b.modifiedAt
            return r
        }
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0 + 200, records.count)]) }) {
            _ = try await database.modifyRecords(saving: chunk, deleting: [], savePolicy: .changedKeys)
        }
    }

    public func pull() async throws -> [Bookmark] {
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        var out: [Bookmark] = []
        var cursor: CKQueryOperation.Cursor?
        var (results, next) = try await database.records(matching: query)
        repeat {
            for (_, result) in results {
                guard let r = try? result.get(), let id = UUID(uuidString: r.recordID.recordName),
                      let url = (r.encryptedValues["url"] as? String).flatMap(URL.init(string:)) else { continue }
                let tags = (r.encryptedValues["tags"] as? String ?? "").split(separator: ",").map(String.init)
                out.append(Bookmark(id: id, url: url, title: r.encryptedValues["title"] as? String ?? "", tags: tags,
                                    isFavourite: (r["isFavourite"] as? Int ?? 0) == 1,
                                    isReadingList: (r["isReadingList"] as? Int ?? 0) == 1,
                                    isRead: (r["isRead"] as? Int ?? 0) == 1,
                                    createdAt: r["createdAt"] as? Date ?? .now, modifiedAt: r["modifiedAt"] as? Date ?? .now))
            }
            cursor = next
            if let c = cursor { (results, next) = try await database.records(continuingMatchFrom: c) }
        } while cursor != nil
        return out
    }
}
#endif
