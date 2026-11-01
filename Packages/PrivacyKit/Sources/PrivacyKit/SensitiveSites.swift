import Foundation
import KageModels

/// Spec 8.5: banking, authentication and health sites are excluded from automatic AI by default.
/// Heuristic only; users can override per site with an explicit warning.
public enum SensitiveSiteClassifier {
    public enum Category: String, Sendable { case banking, authentication, health, payment, government, email }

    static let hostKeywords: [(String, Category)] = [
        ("bank", .banking), ("credit", .banking), ("invest", .banking), ("broker", .banking), ("trading", .banking),
        ("login", .authentication), ("signin", .authentication), ("auth", .authentication), ("sso", .authentication),
        ("accounts.", .authentication), ("idp.", .authentication), ("okta", .authentication),
        ("health", .health), ("clinic", .health), ("hospital", .health), ("patient", .health), ("medical", .health),
        ("mychart", .health), ("pharmacy", .health),
        ("pay", .payment), ("checkout", .payment), ("wallet", .payment),
        ("mail.", .email), ("outlook.", .email),
    ]
    static let knownHosts: [String: Category] = [
        "paypal.com": .payment, "stripe.com": .payment, "wise.com": .banking, "revolut.com": .banking,
        "appleid.apple.com": .authentication, "login.microsoftonline.com": .authentication,
        "accounts.google.com": .authentication, "github.com/login": .authentication,
        "mail.google.com": .email, "irs.gov": .government, "gov.uk": .government, "my.gov.au": .government,
    ]
    static let pathKeywords: [(String, Category)] = [
        ("/login", .authentication), ("/signin", .authentication), ("/sign-in", .authentication),
        ("/oauth", .authentication), ("/password", .authentication), ("/2fa", .authentication),
        ("/checkout", .payment), ("/payment", .payment), ("/billing", .payment),
    ]

    public static func category(for url: URL) -> Category? {
        let host = url.kageHost
        if let c = knownHosts[host] { return c }
        for (h, c) in knownHosts where host.hasSuffix("." + h) { return c }
        if host.hasSuffix(".gov") || host.contains(".gov.") { return .government }
        for (k, c) in hostKeywords where host.contains(k) { return c }
        let path = url.path.lowercased()
        for (k, c) in pathKeywords where path.hasPrefix(k) || path.contains(k + "/") { return c }
        return nil
    }

    public static func isSensitive(_ url: URL) -> Bool { category(for: url) != nil }
}
