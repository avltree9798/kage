import Foundation
import KageModels

/// Cloudflare BYOK credential (spec 8.1). Stored only in the Keychain, never in UserDefaults, logs or sync.
public struct CloudflareCredential: Sendable, Equatable {
    public var accountID: String
    public var apiToken: String
    public init(accountID: String, apiToken: String) { self.accountID = accountID; self.apiToken = apiToken }
}

extension CloudflareCredential: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never prints the token, so a stray `print` or log line cannot leak it (spec 15.2).
    public var description: String { "CloudflareCredential(accountID: \(accountID), apiToken: <redacted>)" }
    public var debugDescription: String { description }
}

public protocol CredentialStoring: Sendable {
    func save(_ credential: CloudflareCredential) async throws
    func load() async throws -> CloudflareCredential?
    func delete() async throws
}

/// Wraps `LocalAuthentication` (spec 7.4).
public protocol Authenticating: Sendable {
    func authenticate(reason: String) async throws -> Bool
}

public enum BlockingMode: String, Codable, Sendable { case off, standard, strict }

/// Wraps `WKContentRuleListStore` (spec 10).
public protocol ContentBlockingManaging: Sendable {
    func compileRules(mode: BlockingMode) async throws
    func setException(for domain: String, enabled: Bool) async
}
