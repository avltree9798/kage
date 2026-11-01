import Foundation
import KageModels
import Persistence

/// Spec 9.3. Protecting a site exempts its chosen storage types from cleanup and keeps its history rows.
public actor ProtectedSiteRegistry {
    private let repository: ProtectedSiteRepository
    private let history: HistoryRepository
    private var cache: [ProtectedSite]?

    /// Identity providers commonly needed to stay signed in to a protected site.
    public static let identityProviderSuggestions: [String: [String]] = [
        "google": ["accounts.google.com"],
        "microsoft": ["login.microsoftonline.com", "login.live.com"],
        "apple": ["appleid.apple.com", "idmsa.apple.com"],
        "github": ["github.com"],
        "okta": ["okta.com"],
    ]

    public init(repository: ProtectedSiteRepository, history: HistoryRepository) {
        self.repository = repository; self.history = history
    }

    public func all() async throws -> [ProtectedSite] {
        if let cache { return cache }
        let sites = try await repository.all()
        cache = sites
        return sites
    }

    public func protect(_ site: ProtectedSite) async throws {
        try await repository.save(site)
        try await history.setProtected(host: site.domain, includeSubdomains: site.includeSubdomains, true)
        cache = nil
    }

    public func unprotect(_ site: ProtectedSite) async throws {
        try await repository.delete(id: site.id)
        try await history.setProtected(host: site.domain, includeSubdomains: site.includeSubdomains, false)
        cache = nil
    }

    public func isProtected(_ url: URL) async -> Bool {
        let host = url.kageHost
        return ((try? await all()) ?? []).contains { $0.matches(host: host) }
    }
}
