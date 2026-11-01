import Foundation
import KageModels

public extension PrivacyProfile {
    // Stable IDs so stores and rows survive relaunch.
    static let standardID = UUID(uuidString: "6B1F1C5E-0000-4000-8000-000000000001")!
    static let ghostID = UUID(uuidString: "6B1F1C5E-0000-4000-8000-000000000002")!
    static let vaultID = UUID(uuidString: "6B1F1C5E-0000-4000-8000-000000000003")!
    static let privateID = UUID(uuidString: "6B1F1C5E-0000-4000-8000-000000000004")!

    /// Spec 9.6. Each persistent profile has its own WebKit store, so cookies never cross profiles.
    static let standard = PrivacyProfile(id: standardID, name: "Standard", kind: .standard, retention: .oneDay,
                                         historyEnabled: true, lockPolicy: .none,
                                         storeStrategy: .persistent(identifier: standardID))
    static let ghost = PrivacyProfile(id: ghostID, name: "Ghost", kind: .ghost, retention: .fifteenMinutes,
                                      historyEnabled: true, lockPolicy: .lockAndForget,
                                      storeStrategy: .persistent(identifier: ghostID))
    static let vault = PrivacyProfile(id: vaultID, name: "Vault", kind: .vault, retention: .manual,
                                      historyEnabled: true, lockPolicy: .lockOnly,
                                      storeStrategy: .persistent(identifier: vaultID))
    static let privateSession = PrivacyProfile(id: privateID, name: "Private", kind: .private, retention: .onTabClose,
                                               historyEnabled: false, lockPolicy: .lockAndDestroyTemporary,
                                               storeStrategy: .nonPersistent)

    static let builtIn: [PrivacyProfile] = [.standard, .ghost, .vault, .privateSession]

    /// Ghost keeps no AI chats; Private keeps nothing on disk (spec 9.6).
    var persistsAIConversations: Bool { kind == .standard || kind == .vault }
    var persistsTabs: Bool { kind != .private }
    var requiresUnlockToOpen: Bool { kind == .vault }

    /// What this profile keeps, in plain words, for the privacy dashboard (spec 24 Q12, ADR-012).
    var preservationSummary: [String] {
        switch kind {
        case .standard: ["History kept for the chosen retention period", "Website data kept except during cleanup",
                         "Protected sites keep their selected storage", "AI chats saved on this device"]
        case .ghost: ["History expires after 15 minutes by default", "Unprotected website data removed at each cleanup",
                      "AI chats are never saved", "Tabs and thumbnails cleared on lock"]
        case .vault: ["History and website data kept until you delete them", "Opening Vault needs Face ID, Touch ID or passcode",
                      "AI chats saved on this device"]
        case .private: ["No history saved", "Website data lives in memory and is discarded when the session ends",
                        "Nothing is sent to AI automatically", "No tab restore after closing"]
        }
    }
}
