import Foundation
#if canImport(NetworkExtension)
import NetworkExtension

/// Installs, starts and watches Kage's WireGuard packet tunnel (ADR-008 rev. 2). The tunnel is a
/// system VPN profile: once connected it carries the whole device's traffic, not only Kage's.
public protocol TunnelManaging: Sendable {
    func connection() async -> TunnelConnection
    func install(_ config: WireGuardConfig, name: String) async throws
    func remove() async throws
    func start() async throws
    func stop() async
    func statusUpdates() -> AsyncStream<TunnelConnection>
}

public final class SystemTunnelManager: TunnelManaging {
    /// Bundle identifier of the packet-tunnel extension embedded in the running app.
    public let providerBundleIdentifier: String
    /// Keychain access group shared with the extension, e.g. `<TeamID>.dev.kage.shared`.
    public let accessGroup: String?

    public init(providerBundleIdentifier: String, accessGroup: String?) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.accessGroup = accessGroup
    }

    /// Default identifiers for the running app: `<app bundle id>.tunnel`, and the shared group from
    /// the `KageKeychainGroup` Info.plist key (set by the build).
    public static func forMainBundle() -> SystemTunnelManager {
        let app = Bundle.main.bundleIdentifier ?? "dev.kage.ios"
        let group = Bundle.main.object(forInfoDictionaryKey: "KageKeychainGroup") as? String
        return SystemTunnelManager(providerBundleIdentifier: app + ".tunnel",
                                   accessGroup: group.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 })
    }

    private func existing() async throws -> NETunnelProviderManager? {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        return all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier }
    }

    public func connection() async -> TunnelConnection {
        guard let m = try? await existing() else { return .notInstalled }
        return Self.map(m.connection.status)
    }

    public func install(_ config: WireGuardConfig, name: String) async throws {
        let manager = try await existing() ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        if let old = proto.passwordReference { TunnelKeychain.delete(persistentReference: old) }
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = config.peers.first?.endpoint ?? "WireGuard"
        proto.passwordReference = try TunnelKeychain.save(config.wgQuickText, account: providerBundleIdentifier, accessGroup: accessGroup)
        proto.providerConfiguration = nil  // Nothing secret goes in the profile itself.
        proto.includeAllNetworks = config.routesAllTraffic
        proto.excludeLocalNetworks = true
        manager.protocolConfiguration = proto
        manager.localizedDescription = name
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    public func remove() async throws {
        guard let m = try await existing() else { return }
        m.connection.stopVPNTunnel()
        if let ref = (m.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference {
            TunnelKeychain.delete(persistentReference: ref)
        }
        try await m.removeFromPreferences()
    }

    public func start() async throws {
        guard let m = try await existing() else { throw NEVPNError(.configurationInvalid) }
        if !m.isEnabled { m.isEnabled = true; try await m.saveToPreferences(); try await m.loadFromPreferences() }
        try m.connection.startVPNTunnel()
    }

    public func stop() async {
        (try? await existing())?.connection.stopVPNTunnel()
    }

    public func statusUpdates() -> AsyncStream<TunnelConnection> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: nil) { note in
                guard let conn = note.object as? NEVPNConnection else { return }
                continuation.yield(Self.map(conn.status))
            }
            let token = UncheckedObserver(observer)
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token.value) }
        }
    }

    static func map(_ status: NEVPNStatus) -> TunnelConnection {
        switch status {
        case .invalid: .invalid
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .reasserting: .reasserting
        case .disconnecting: .disconnecting
        @unknown default: .invalid
        }
    }
}

private struct UncheckedObserver: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}
#endif
