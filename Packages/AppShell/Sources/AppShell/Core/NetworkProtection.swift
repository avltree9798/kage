import Foundation
import Observation

/// Spec 11.3. Only `verifiedConnected` may show a filled shield, and Kage has no authoritative
/// WARP integration yet (ADR-008), so that state is never produced today (AT16).
public enum NetworkProtectionState: Equatable, Sendable {
    case notConfigured
    case statusUnknown(detail: String?)
    case connecting
    case verifiedConnected
    case disconnected
    case restricted(String)

    public var title: String {
        switch self {
        case .notConfigured: "Not set up"
        case .statusUnknown: "Status unknown"
        case .connecting: "Connecting"
        case .verifiedConnected: "Protected by WARP"
        case .disconnected: "Not connected"
        case .restricted(let why): "Unavailable: \(why)"
        }
    }

    /// The UI may claim encryption only in the verified state.
    public var claimsProtection: Bool { self == .verifiedConnected }

    public var symbol: String { claimsProtection ? "shield.lefthalf.filled" : "shield.slash" }
}

/// Phase A (spec 11.1): guide the user to the official WARP client. Kage reads no tunnel status it can't verify.
@MainActor @Observable
public final class NetworkProtectionMonitor {
    public private(set) var state: NetworkProtectionState = .notConfigured
    public var userSaysWARPInstalled = false {
        didSet { state = userSaysWARPInstalled ? .statusUnknown(detail: nil) : .notConfigured }
    }
    public private(set) var traceNote: String?

    public static let warpDownloadURL = URL(string: "https://one.one.one.one/")!
    public static let warpAppStoreURL = URL(string: "https://apps.apple.com/app/id1423538627")!

    public init() {}

    /// Optional, user-triggered check of Cloudflare's public trace endpoint. Its answer is shown as
    /// an observation from Cloudflare, never as verified protection, and the state stays unknown.
    public func checkTrace(session: URLSession = .shared) async {
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace"),
              let (data, _) = try? await session.data(from: url),
              let text = String(data: data, encoding: .utf8) else {
            traceNote = "Couldn't reach Cloudflare to check."
            return
        }
        let warp = text.split(separator: "\n").first { $0.hasPrefix("warp=") }?.dropFirst(5) ?? "unknown"
        traceNote = warp == "off" ? "Cloudflare doesn't see this traffic coming through WARP."
            : "Cloudflare reports warp=\(warp) for this connection. Kage can't verify this itself."
        state = .statusUnknown(detail: traceNote)
    }
}
