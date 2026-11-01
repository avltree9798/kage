import Foundation

/// Decides what to do with a URL before WebKit loads it (spec 6.1, 13.4 step 4; threat model: untrusted links).
public enum NavigationDecision: Equatable, Sendable {
    case allow
    /// Hand off to another app only after the user confirms (spec 15.2: safe external-app handoff).
    case askToOpenExternally(URL)
    case block(reason: String)
}

public enum NavigationPolicy {
    public static let webSchemes: Set<String> = ["http", "https"]
    /// Schemes WebKit handles internally for subframes and in-page content.
    public static let internalSchemes: Set<String> = ["about", "blob", "data"]
    public static let externalSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "itms-apps", "itms-appss", "apps", "shortcuts",
    ]

    public static func decide(_ url: URL, isMainFrame: Bool, userInitiated: Bool) -> NavigationDecision {
        guard let scheme = url.scheme?.lowercased() else { return .block(reason: "Invalid address") }
        if webSchemes.contains(scheme) { return .allow }
        if scheme == "about" { return url.absoluteString == "about:blank" || !isMainFrame ? .allow : .block(reason: "Unsupported page") }
        if scheme == "blob" { return .allow }
        if scheme == "data" {
            // Top-level data: URLs are a phishing vector; allow only in subframes.
            return isMainFrame ? .block(reason: "Kage does not open data: addresses as pages") : .allow
        }
        if scheme == "javascript" { return .block(reason: "Scripts can't be run from links") }
        if scheme == "file" { return .block(reason: "Local files can't be opened this way") }
        if externalSchemes.contains(scheme) || isMainFrame {
            // Unknown custom schemes are app links; ask, and never open without a user gesture.
            return userInitiated ? .askToOpenExternally(url) : .block(reason: "A page tried to open another app")
        }
        return .block(reason: "Unsupported link")
    }
}
