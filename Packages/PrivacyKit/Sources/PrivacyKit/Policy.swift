import Foundation
import KageModels

public struct SitePrivacyPolicy: Sendable, Equatable {
    public var recordHistory: Bool
    public var retention: RetentionInterval
    public var protectedDataKinds: Set<WebsiteDataKind>
    /// Sensitive sites and private sessions never auto-submit to AI (spec 8.5).
    public var allowAutomaticAI: Bool
    public var isSensitive: Bool

    public init(recordHistory: Bool, retention: RetentionInterval, protectedDataKinds: Set<WebsiteDataKind>,
                allowAutomaticAI: Bool, isSensitive: Bool) {
        self.recordHistory = recordHistory; self.retention = retention; self.protectedDataKinds = protectedDataKinds
        self.allowAutomaticAI = allowAutomaticAI; self.isSensitive = isSensitive
    }
}

public protocol PrivacyPolicyEvaluating: Sendable {
    func policy(for site: URL, profileID: UUID) async -> SitePrivacyPolicy
}

