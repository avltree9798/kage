import Foundation
#if canImport(Security)
import Security

/// Stores the wg-quick text (it contains the private key) in a Keychain access group shared with the
/// tunnel extension. The VPN profile only carries a persistent reference to the item, never the key.
public enum TunnelKeychain {
    public static let service = "dev.kage.tunnel"

    public enum KeychainError: Error, Equatable { case status(OSStatus), missingReference }

    /// Saves or replaces the config and returns its persistent reference.
    public static func save(_ text: String, account: String, accessGroup: String?) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(text.utf8)
        // The tunnel may start before first unlock after a reboot (on-demand), so "after first unlock".
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        add[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        let status = SecItemAdd(add as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let ref = result as? Data else { throw KeychainError.missingReference }
        return ref
    }

    public static func load(persistentReference ref: Data) -> String? {
        let query: [String: Any] = [
            kSecValuePersistentRef as String: ref,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, var data = result as? Data else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(persistentReference ref: Data) {
        SecItemDelete([kSecValuePersistentRef as String: ref] as CFDictionary)
    }
}
#endif
