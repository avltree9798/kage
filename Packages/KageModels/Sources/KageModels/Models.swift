import Foundation

/// Lifecycle states from spec section 6.2.
public enum TabState: String, Codable, Sendable, CaseIterable {
    case active, background, suspended, archived, privateSession
}

/// Spec 14.1.
public struct BrowserTab: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var url: URL?
    public var title: String
    public var groupID: UUID?
    public var profileID: UUID
    public var createdAt: Date
    public var lastActiveAt: Date
    public var state: TabState
    public var isProtected: Bool
    public var isPinned: Bool
    public var sortOrder: Int
    public var snapshotReference: String?
    /// Opaque `WKWebView.interactionState` archive used to restore a suspended tab's back/forward list.
    public var interactionState: Data?

    public init(id: UUID = UUID(), url: URL?, title: String = "", groupID: UUID? = nil,
                profileID: UUID, createdAt: Date = .now, lastActiveAt: Date = .now,
                state: TabState = .background, isProtected: Bool = false, isPinned: Bool = false,
                sortOrder: Int = 0, snapshotReference: String? = nil, interactionState: Data? = nil) {
        self.id = id; self.url = url; self.title = title; self.groupID = groupID
        self.profileID = profileID; self.createdAt = createdAt; self.lastActiveAt = lastActiveAt
        self.state = state; self.isProtected = isProtected; self.isPinned = isPinned
        self.sortOrder = sortOrder; self.snapshotReference = snapshotReference
        self.interactionState = interactionState
    }
}

/// Spec 14.2.
public struct TabGroup: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var colour: String
    public var sortOrder: Int
    public var defaultProfileID: UUID?

    public init(id: UUID = UUID(), name: String, colour: String, sortOrder: Int, defaultProfileID: UUID? = nil) {
        self.id = id; self.name = name; self.colour = colour; self.sortOrder = sortOrder
        self.defaultProfileID = defaultProfileID
    }
}

/// Spec 14.3. `expiresAt` is nil when the profile keeps history indefinitely.
public struct HistoryVisit: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var firstVisitedAt: Date
    public var lastVisitedAt: Date
    public var visitCount: Int
    public var expiresAt: Date?
    public var isProtected: Bool

    public init(id: UUID = UUID(), url: URL, title: String = "", firstVisitedAt: Date,
                lastVisitedAt: Date, visitCount: Int = 1, expiresAt: Date?, isProtected: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.firstVisitedAt = firstVisitedAt
        self.lastVisitedAt = lastVisitedAt; self.visitCount = visitCount
        self.expiresAt = expiresAt; self.isProtected = isProtected
    }
}

/// WebKit storage types a protected site may keep (spec 9.3: display exactly which are exempted).
public enum WebsiteDataKind: String, Codable, Sendable, CaseIterable {
    case cookies, localStorage, sessionStorage, indexedDB, cache, serviceWorkers
}

/// Spec 14.4.
public struct ProtectedSite: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var domain: String
    public var includeSubdomains: Bool
    public var allowedDataTypes: Set<WebsiteDataKind>
    public var createdAt: Date
    public var notes: String?

    public init(id: UUID = UUID(), domain: String, includeSubdomains: Bool = true,
                allowedDataTypes: Set<WebsiteDataKind> = [.cookies, .localStorage, .indexedDB],
                createdAt: Date = .now, notes: String? = nil) {
        self.id = id; self.domain = domain.lowercased(); self.includeSubdomains = includeSubdomains
        self.allowedDataTypes = allowedDataTypes; self.createdAt = createdAt; self.notes = notes
    }

    /// True when `host` is this domain, or a subdomain of it when `includeSubdomains` is set.
    public func matches(host: String) -> Bool {
        let host = host.lowercased()
        if host == domain { return true }
        return includeSubdomains && host.hasSuffix("." + domain)
    }
}

/// Spec 9.4 retention modes.
public enum RetentionInterval: Codable, Sendable, Hashable {
    case onTabClose
    case minutes(Int)
    case manual

    public static let fiveMinutes = RetentionInterval.minutes(5)
    public static let fifteenMinutes = RetentionInterval.minutes(15)
    public static let thirtyMinutes = RetentionInterval.minutes(30)
    public static let oneHour = RetentionInterval.minutes(60)
    public static let oneDay = RetentionInterval.minutes(24 * 60)

    /// Spec 9.4: `expiresAt = lastVisitedAt + retentionInterval`.
    /// Tab-close expiry is driven by the tab lifecycle, and manual never expires, so both return nil.
    public func expiry(after lastVisitedAt: Date) -> Date? {
        switch self {
        case .minutes(let m): return lastVisitedAt.addingTimeInterval(TimeInterval(m) * 60)
        case .onTabClose, .manual: return nil
        }
    }
}

/// How a profile maps onto WebKit data stores (spec 9.6, ADR-004).
public enum StoreStrategy: Codable, Sendable, Hashable {
    /// A persistent store created with `WKWebsiteDataStore(forIdentifier:)`.
    case persistent(identifier: UUID)
    /// `WKWebsiteDataStore.nonPersistent()`; discarded with the session.
    case nonPersistent
}

public enum LockPolicy: String, Codable, Sendable { case none, lockOnly, lockAndForget, lockAndDestroyTemporary }

/// Spec 14.5.
public struct PrivacyProfile: Identifiable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case standard, ghost, vault, `private` }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var retention: RetentionInterval
    public var historyEnabled: Bool
    public var aiAutoProcessing: Bool
    public var lockPolicy: LockPolicy
    public var storeStrategy: StoreStrategy

    public init(id: UUID = UUID(), name: String, kind: Kind, retention: RetentionInterval,
                historyEnabled: Bool, aiAutoProcessing: Bool = false, lockPolicy: LockPolicy,
                storeStrategy: StoreStrategy) {
        self.id = id; self.name = name; self.kind = kind; self.retention = retention
        self.historyEnabled = historyEnabled; self.aiAutoProcessing = aiAutoProcessing
        self.lockPolicy = lockPolicy; self.storeStrategy = storeStrategy
    }
}

/// Spec 14.6.
public struct AISession: Identifiable, Codable, Sendable, Hashable {
    public struct Message: Codable, Sendable, Hashable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public var role: Role
        public var text: String
        public init(role: Role, text: String) { self.role = role; self.text = text }
    }
    public var id: UUID
    public var tabIDs: [UUID]
    public var modelID: String
    public var createdAt: Date
    public var expiresAt: Date?
    public var localMessages: [Message]
    public var sourceReferences: [URL]

    public init(id: UUID = UUID(), tabIDs: [UUID], modelID: String, createdAt: Date = .now,
                expiresAt: Date? = nil, localMessages: [Message] = [], sourceReferences: [URL] = []) {
        self.id = id; self.tabIDs = tabIDs; self.modelID = modelID; self.createdAt = createdAt
        self.expiresAt = expiresAt; self.localMessages = localMessages; self.sourceReferences = sourceReferences
    }
}

/// Spec 14.7.
public struct DownloadRecord: Identifiable, Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, inProgress, paused, completed, failed, cancelled }
    public var id: UUID
    public var sourceURL: URL
    public var filename: String
    public var destinationBookmark: Data?
    public var status: Status
    public var progress: Double?
    public var createdAt: Date

    public init(id: UUID = UUID(), sourceURL: URL, filename: String, destinationBookmark: Data? = nil,
                status: Status = .pending, progress: Double? = nil, createdAt: Date = .now) {
        self.id = id; self.sourceURL = sourceURL; self.filename = filename
        self.destinationBookmark = destinationBookmark; self.status = status
        self.progress = progress; self.createdAt = createdAt
    }
}
