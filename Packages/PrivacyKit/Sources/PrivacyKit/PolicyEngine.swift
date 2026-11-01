import Foundation
import KageModels
import Persistence

/// Answers "what may Kage do on this site, in this profile?" (spec 13.3 PrivacyPolicyEvaluating).
public actor PrivacyPolicyEngine: PrivacyPolicyEvaluating {
    private var profiles: [UUID: PrivacyProfile]
    private var protectedSites: [ProtectedSite]
    /// Hosts where the user explicitly allowed automatic AI despite a sensitive category.
    private var aiOverrides: Set<String>

    public init(profiles: [PrivacyProfile] = PrivacyProfile.builtIn, protectedSites: [ProtectedSite] = [],
                aiOverrides: Set<String> = []) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        self.protectedSites = protectedSites
        self.aiOverrides = aiOverrides
    }

    public func update(profile: PrivacyProfile) { profiles[profile.id] = profile }
    public func update(protectedSites: [ProtectedSite]) { self.protectedSites = protectedSites }
    public func setAIOverride(host: String, allowed: Bool) {
        if allowed { aiOverrides.insert(host) } else { aiOverrides.remove(host) }
    }
    public func profile(id: UUID) -> PrivacyProfile { profiles[id] ?? .standard }
    public var allProfiles: [PrivacyProfile] { Array(profiles.values).sorted { $0.name < $1.name } }
    public var currentProtectedSites: [ProtectedSite] { protectedSites }

    public func policy(for site: URL, profileID: UUID) -> SitePrivacyPolicy {
        let profile = profile(id: profileID)
        let host = site.kageHost
        let protected = protectedSites.first { $0.matches(host: host) }
        let sensitive = SensitiveSiteClassifier.isSensitive(site)
        let autoAI = profile.kind != .private && profile.aiAutoProcessing && (!sensitive || aiOverrides.contains(host))
        return SitePrivacyPolicy(recordHistory: profile.historyEnabled,
                                 retention: protected != nil && profile.kind != .private ? .manual : profile.retention,
                                 protectedDataKinds: protected?.allowedDataTypes ?? [],
                                 allowAutomaticAI: autoAI,
                                 isSensitive: sensitive)
    }

    public func expiry(for site: URL, profileID: UUID, visitedAt: Date) -> Date? {
        policy(for: site, profileID: profileID).retention.expiry(after: visitedAt)
    }
}
