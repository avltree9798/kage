import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

public enum VaultKeyError: Error, Equatable, Sendable {
    case locked, authenticationFailed, unavailable, keychain(OSStatus)
}

/// The Vault's data key (threat model T-10/T-11). It exists in memory only while the Vault is unlocked,
/// and only the Secure Enclave can produce it, after Face ID, Touch ID or the device passcode. Hooking
/// the app's unlock check doesn't help an attacker, because no key comes out of the Enclave without
/// user presence. CryptoKit zeroes `SymmetricKey` storage when it's released.
public protocol VaultKeyProviding: Sendable {
    var isUnlocked: Bool { get async }
    /// Prompts for user presence and keeps the key until `lock()`.
    func unlock(reason: String) async throws
    /// Drops the key; any later use throws `VaultKeyError.locked`.
    func lock() async
    func key() async throws -> SymmetricKey
}

/// Test and preview provider. Never used for real Vault data.
public actor InMemoryVaultKey: VaultKeyProviding {
    private let material: SymmetricKey
    private var unlocked = false
    public var allowUnlock = true
    public init(_ key: SymmetricKey = SymmetricKey(size: .bits256)) { material = key }
    public var isUnlocked: Bool { unlocked }
    public func unlock(reason: String) throws {
        guard allowUnlock else { throw VaultKeyError.authenticationFailed }
        unlocked = true
    }
    public func lock() { unlocked = false }
    public func key() throws -> SymmetricKey {
        guard unlocked else { throw VaultKeyError.locked }
        return material
    }
    public func setAllowUnlock(_ v: Bool) { allowUnlock = v }
}

#if canImport(CryptoKit) && canImport(LocalAuthentication) && canImport(Security)
import Security

/// Secure Enclave implementation. A P-256 key-agreement key is created inside the Enclave with
/// `.privateKeyUsage` + `.userPresence`; only its encrypted handle is stored in the Keychain. The data key
/// is HKDF(ECDH(enclaveKey, storedPeerPublicKey)). Without the Enclave (some Macs, simulators) the data
/// key is a random key stored in the Keychain behind `.userPresence` access control instead.
public actor SecureEnclaveVaultKey: VaultKeyProviding {
    private let service: String
    private var current: SymmetricKey?

    public init(service: String = "dev.kage.vault") { self.service = service }

    public var isUnlocked: Bool { current != nil }

    public func lock() { current = nil }

    public func key() throws -> SymmetricKey {
        guard let current else { throw VaultKeyError.locked }
        return current
    }

    public func unlock(reason: String) async throws {
        let context = LAContext()
        context.localizedReason = reason
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw VaultKeyError.authenticationFailed
            }
        } catch let e as VaultKeyError { throw e } catch { throw VaultKeyError.authenticationFailed }
        current = try SecureEnclave.isAvailable ? enclaveKey(context: context) : keychainKey(context: context)
    }

    // MARK: Secure Enclave path

    private func enclaveKey(context: LAContext) throws -> SymmetricKey {
        let handle: SecureEnclave.P256.KeyAgreement.PrivateKey
        if let stored = try item("enclave-key", context: context) {
            handle = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored, authenticationContext: context)
        } else {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               [.privateKeyUsage, .userPresence], &error) else {
                throw VaultKeyError.unavailable
            }
            handle = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
            try store("enclave-key", handle.dataRepresentation, access: nil)
        }
        let peer: P256.KeyAgreement.PublicKey
        if let stored = try item("peer", context: nil) {
            peer = try P256.KeyAgreement.PublicKey(rawRepresentation: stored)
        } else {
            peer = P256.KeyAgreement.PrivateKey().publicKey   // its private half is discarded immediately
            try store("peer", peer.rawRepresentation, access: nil)
        }
        let shared = try handle.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("dev.kage.vault.v1".utf8),
                                              sharedInfo: Data("vault-data-key".utf8), outputByteCount: 32)
    }

    // MARK: Fallback path (no Secure Enclave)

    private func keychainKey(context: LAContext) throws -> SymmetricKey {
        if var raw = try item("data-key", context: context) {
            defer { raw.secureWipe() }
            return SymmetricKey(data: raw)
        }
        let key = SymmetricKey(size: .bits256)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .userPresence, &error) else { throw VaultKeyError.unavailable }
        var raw = key.withUnsafeBytes { Data($0) }
        defer { raw.secureWipe() }
        try store("data-key", raw, access: access)
        return key
    }

    // MARK: Keychain

    private func item(_ account: String, context: LAContext?) throws -> Data? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let context { q[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultKeyError.keychain(status) }
        return out as? Data
    }

    private func store(_ account: String, _ data: Data, access: SecAccessControl?) throws {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let access { q[kSecAttrAccessControl as String] = access }
        else { q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultKeyError.keychain(status) }
    }
}
#endif
