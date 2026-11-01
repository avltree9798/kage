import Foundation
import Observation
#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// Encrypted DNS when the tunnel is off (threat model T-13). Without it, the Wi-Fi network and the ISP
/// can read every hostname Kage looks up. WebKit resolves names in its own process, which per-app
/// resolver settings don't reach, so Kage installs a system DNS-over-HTTPS configuration with
/// `NEDNSSettingsManager`. The system makes the user turn it on once in Settings; Kage can't do that itself.
@MainActor @Observable
public final class EncryptedDNSManager {
    public enum Status: Equatable, Sendable {
        case unavailable
        case notInstalled
        /// Saved, but the user hasn't selected it in Settings yet.
        case installedNotEnabled
        case active
        case failed(String)
    }

    public private(set) var status: Status = .notInstalled

    public static let serverURL = URL(string: "https://cloudflare-dns.com/dns-query")!
    public static let servers = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]

    public init() {}

    public func refresh() async {
        #if canImport(NetworkExtension)
        let m = NEDNSSettingsManager.shared()
        do {
            try await m.loadFromPreferences()
            if m.dnsSettings == nil { status = .notInstalled }
            else { status = m.isEnabled ? .active : .installedNotEnabled }
        } catch {
            status = .notInstalled
        }
        #else
        status = .unavailable
        #endif
    }

    public func install() async {
        #if canImport(NetworkExtension)
        let m = NEDNSSettingsManager.shared()
        do {
            try await m.loadFromPreferences()
            let settings = NEDNSOverHTTPSSettings(servers: Self.servers)
            settings.serverURL = Self.serverURL
            m.dnsSettings = settings
            m.localizedDescription = "Kage encrypted DNS (Cloudflare 1.1.1.1)"
            try await m.saveToPreferences()
            await refresh()
        } catch {
            status = .failed(error.localizedDescription)
        }
        #endif
    }

    public func remove() async {
        #if canImport(NetworkExtension)
        let m = NEDNSSettingsManager.shared()
        do {
            try await m.loadFromPreferences()
            try await m.removeFromPreferences()
            status = .notInstalled
        } catch {
            status = .failed(error.localizedDescription)
        }
        #endif
    }

    public var explanation: String {
        switch status {
        case .unavailable: return "Encrypted DNS isn't available on this device."
        case .notInstalled: return "Hostnames you visit are looked up in the clear unless the tunnel is on."
        case .installedNotEnabled:
            #if os(iOS)
            return "Saved. Turn it on in Settings › General › VPN & Device Management › DNS."
            #else
            return "Saved. Turn it on in System Settings › Network › VPN & Filters."
            #endif
        case .active:
            return "Hostname lookups are encrypted to Cloudflare 1.1.1.1. Your network sees only that you use encrypted DNS."
        case .failed(let m): return "Encrypted DNS couldn't be saved: \(m)"
        }
    }
}
