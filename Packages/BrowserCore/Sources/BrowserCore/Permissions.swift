import Foundation
import KageModels
import Persistence

/// Per-site decisions for camera, microphone, popups and other settings (spec 6.8).
/// OS-level permission still applies on top; Kage never bypasses it.
public actor SitePermissionStore {
    private let repository: SiteSettingsRepository?
    private var memory: [String: [String: String]] = [:]

    public init(repository: SiteSettingsRepository?) { self.repository = repository }

    public func get(_ permission: SitePermission, host: String) async -> PermissionDecision {
        if let v = memory[host]?[permission.rawValue] { return PermissionDecision(rawValue: v) ?? .ask }
        let v = try? await repository?.value(host: host, key: permission.rawValue)
        return v.flatMap { PermissionDecision(rawValue: $0) } ?? .ask
    }

    public func set(_ permission: SitePermission, host: String, _ decision: PermissionDecision) async {
        memory[host, default: [:]][permission.rawValue] = decision.rawValue
        try? await repository?.set(host: host, key: permission.rawValue, value: decision == .ask ? nil : decision.rawValue)
    }

    /// Combined decision for a media request: deny if either is denied, allow only if all requested are allowed.
    public func decision(host: String, camera: Bool, microphone: Bool) async -> PermissionDecision {
        var parts: [PermissionDecision] = []
        if camera { parts.append(await get(.camera, host: host)) }
        if microphone { parts.append(await get(.microphone, host: host)) }
        if parts.contains(.deny) { return .deny }
        if !parts.isEmpty && parts.allSatisfy({ $0 == .allow }) { return .allow }
        return .ask
    }

    public func all(host: String) async -> [SitePermission: PermissionDecision] {
        var out: [SitePermission: PermissionDecision] = [:]
        for p in SitePermission.allCases { out[p] = await get(p, host: host) }
        return out
    }

    public func reset(host: String) async {
        memory[host] = nil
        for p in SitePermission.allCases { try? await repository?.set(host: host, key: p.rawValue, value: nil) }
    }
}
