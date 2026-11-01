import Foundation

/// Spec 6.5. Saved content persists unless deleted; history expiry never touches it.
public struct Bookmark: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var folderID: UUID?
    public var tags: [String]
    public var isFavourite: Bool
    public var isReadingList: Bool
    public var isRead: Bool
    /// Explicitly saved offline text for the reading list.
    public var savedContent: String?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), url: URL, title: String, folderID: UUID? = nil, tags: [String] = [],
                isFavourite: Bool = false, isReadingList: Bool = false, isRead: Bool = false,
                savedContent: String? = nil, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id; self.url = url; self.title = title; self.folderID = folderID; self.tags = tags
        self.isFavourite = isFavourite; self.isReadingList = isReadingList; self.isRead = isRead
        self.savedContent = savedContent; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

public struct BookmarkFolder: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var sortOrder: Int
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.parentID = parentID; self.sortOrder = sortOrder
    }
}

/// Per-site decisions (spec 6.8). Values are stored as strings so new keys need no migration.
public enum SitePermission: String, Codable, Sendable, CaseIterable {
    case camera, microphone, popups, desktopSite, aiAllowed, contentBlockingException, zoom
}

public enum PermissionDecision: String, Codable, Sendable { case ask, allow, deny }

public struct ResearchNote: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var sessionID: UUID?
    public var text: String
    public var sourceURL: URL?
    public var createdAt: Date
    public init(id: UUID = UUID(), sessionID: UUID? = nil, text: String, sourceURL: URL? = nil, createdAt: Date = .now) {
        self.id = id; self.sessionID = sessionID; self.text = text; self.sourceURL = sourceURL; self.createdAt = createdAt
    }
}

public extension URL {
    /// Lower-cased host without a leading "www.".
    var kageHost: String {
        let h = (host ?? "").lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
