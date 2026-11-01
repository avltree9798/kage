import Foundation
import KageModels

public struct SitePrivacyPolicy: Sendable, Equatable {
    public var recordHistory: Bool
    public var retention: RetentionInterval
    public var protectedDataKinds: Set<WebsiteDataKind>
    /// Sensitive sites and private sessions never auto-submit to AI (spec 8.5).
    public var allowAutomaticAI: Bool
}

public protocol PrivacyPolicyEvaluating: Sendable {
    func policy(for site: URL, profileID: UUID) async -> SitePrivacyPolicy
}

/// Conceals content before any asynchronous cleanup (spec 7.4, AT10).
public protocol SessionLocking: Sendable {
    /// Must cover web content and previews within 250 ms of an observable lock event.
    @MainActor func conceal()
    func unlock() async throws
}
