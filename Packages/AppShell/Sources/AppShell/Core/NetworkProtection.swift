import Foundation
import Observation
import NetworkTunnel

/// Spec 11.3. Only `verifiedConnected` may show a filled shield. It needs both of these: Kage's own tunnel
/// is up (the system says so), and Cloudflare's trace confirms the traffic arrives through WARP (AT16).
public enum NetworkProtectionState: Equatable, Sendable {
    case notConfigured
    case statusUnknown(detail: String?)
    case connecting
    case verifiedConnected
    /// Kage's tunnel is up but Cloudflare doesn't see WARP, e.g. a non-WARP WireGuard provider.
    case tunnelWithoutWARP(exitIP: String?)
    case disconnected
    case restricted(String)

    public var title: String {
        switch self {
        case .notConfigured: "Not set up"
        case .statusUnknown: "Status unknown"
        case .connecting: "Connecting"
        case .verifiedConnected: "Protected by WARP"
        case .tunnelWithoutWARP: "Tunnel on, not WARP"
        case .disconnected: "Not connected"
        case .restricted(let why): "Unavailable: \(why)"
        }
    }

    /// The UI may claim WARP protection only in the verified state.
    public var claimsProtection: Bool { self == .verifiedConnected }

    public var symbol: String {
        switch self {
        case .verifiedConnected: "shield.lefthalf.filled"
        case .tunnelWithoutWARP: "lock.shield"
        default: "shield.slash"
        }
    }

    /// Pure state rule, tested on its own.
    /// - tunnel: Kage's tunnel status, or `nil` when the platform has none.
    /// - trace: Cloudflare's trace taken while that status held, or `nil` if not checked or unreachable.
    public static func resolve(tunnel: TunnelConnection?, trace: CloudflareTrace?, userSaysWARPInstalled: Bool) -> Self {
        switch tunnel {
        case nil, .notInstalled?:
            return userSaysWARPInstalled ? .statusUnknown(detail: nil) : .notConfigured
        case .invalid?:
            return .restricted("the VPN profile was removed or turned off in Settings")
        case .connecting?, .reasserting?:
            return .connecting
        case .disconnected?, .disconnecting?:
            return .disconnected
        case .connected?:
            guard let trace else { return .statusUnknown(detail: "Tunnel connected. Checking with Cloudflare…") }
            return trace.confirmsWARP ? .verifiedConnected : .tunnelWithoutWARP(exitIP: trace.ip)
        }
    }
}

/// Network Protection (spec 11). Phase A guided users to the WARP app; Kage now also runs its own WireGuard
/// tunnel (ADR-008 rev. 2) from a config the user imports, and verifies it with Cloudflare.
@MainActor @Observable
public final class NetworkProtectionMonitor {
    public private(set) var state: NetworkProtectionState = .notConfigured
    public private(set) var tunnel: TunnelConnection?
    public private(set) var lastTrace: CloudflareTrace?
    public private(set) var traceNote: String?
    public private(set) var lastError: String?
    public var userSaysWARPInstalled = false { didSet { recompute() } }

    public static let warpDownloadURL = URL(string: "https://one.one.one.one/")!
    public static let warpAppStoreURL = URL(string: "https://apps.apple.com/app/id1423538627")!

    @ObservationIgnored private let manager: (any TunnelManaging)?
    @ObservationIgnored private let traceFetcher: @Sendable () async throws -> CloudflareTrace
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public init(manager: (any TunnelManaging)? = nil,
                traceFetcher: @escaping @Sendable () async throws -> CloudflareTrace = { try await CloudflareTrace.fetch() }) {
        self.manager = manager
        self.traceFetcher = traceFetcher
    }

    public var hasTunnelSupport: Bool { manager != nil }
    public var tunnelInstalled: Bool { tunnel != nil && tunnel != .notInstalled }

    private func recompute() {
        state = .resolve(tunnel: tunnel, trace: tunnel == .connected ? lastTrace : nil, userSaysWARPInstalled: userSaysWARPInstalled)
    }

    /// Reads the current tunnel status and follows system changes.
    public func start() async {
        guard let manager, watchTask == nil else { return }
        await apply(await manager.connection())
        watchTask = Task { [weak self] in
            for await status in manager.statusUpdates() {
                guard let self else { return }
                await self.apply(status)
            }
        }
    }

    func apply(_ status: TunnelConnection) async {
        let changed = status != tunnel
        tunnel = status
        if changed { lastTrace = nil }
        recompute()
        if status == .connected && lastTrace == nil { await verify() }
    }

    /// Asks Cloudflare which way this traffic arrived. Only `warp=on`/`plus` while the tunnel is up counts.
    public func verify() async {
        do {
            let trace = try await traceFetcher()
            lastTrace = trace
            traceNote = trace.confirmsWARP ? "Cloudflare confirms this connection arrives through WARP."
                : "Cloudflare reports warp=\(trace.warp.rawValue) for this connection."
        } catch {
            lastTrace = nil
            traceNote = "Couldn't reach Cloudflare to check."
        }
        recompute()
    }

    /// Phase A path: a user-triggered check while using Cloudflare's own app.
    public func checkTrace() async { await verify() }

    public func importConfig(_ text: String, name: String = "Kage WARP") async -> Bool {
        guard let manager else { lastError = "This build has no tunnel."; return false }
        do {
            let config = try WireGuardConfig.parse(text)
            try await manager.install(config, name: name)
            lastError = nil
            await apply(await manager.connection())
            return true
        } catch let e as WireGuardConfig.ParseError {
            lastError = e.description
        } catch {
            lastError = "The system didn't save the VPN profile. You may have declined the permission prompt."
        }
        return false
    }

    public func connect() async {
        guard let manager else { return }
        do { try await manager.start(); lastError = nil } catch { lastError = "Couldn't start the tunnel." }
    }

    public func disconnect() async { await manager?.stop() }

    public func removeTunnel() async {
        guard let manager else { return }
        try? await manager.remove()
        await apply(.notInstalled)
    }
}
