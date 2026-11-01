import Foundation
#if canImport(Security)
import Security

public enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedItem
}

/// Stores the Cloudflare credential as one generic-password item (spec 8.1, ADR-003).
/// This-device-only and never synchronised, so it cannot reach iCloud Keychain or backups.
public struct KeychainCredentialStore: CredentialStoring {
    public let service: String
    public let account: String

    public init(service: String = "dev.kage.cloudflare", account: String = "workers-ai") {
        self.service = service; self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func save(_ credential: CloudflareCredential) async throws {
        let payload = try JSONEncoder().encode(["accountID": credential.accountID, "apiToken": credential.apiToken])
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func load() async throws -> CloudflareCredential? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = out as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let acct = dict["accountID"], let token = dict["apiToken"] else { throw KeychainError.malformedItem }
        return CloudflareCredential(accountID: acct, apiToken: token)
    }

    public func delete() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}
#endif

/// For tests, previews and the Private profile.
public actor InMemoryCredentialStore: CredentialStoring {
    private var value: CloudflareCredential?
    public init(_ value: CloudflareCredential? = nil) { self.value = value }
    public func save(_ credential: CloudflareCredential) { value = credential }
    public func load() -> CloudflareCredential? { value }
    public func delete() { value = nil }
}
