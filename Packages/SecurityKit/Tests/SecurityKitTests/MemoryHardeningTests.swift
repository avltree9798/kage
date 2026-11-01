import Foundation
import Testing
import CryptoKit
@testable import SecurityKit

@Suite struct SecureBytesTests {
    @Test func holdsBytesUntilWiped() {
        let s = SecureBytes(Array("wg-private-key".utf8))
        #expect(s.utf8String() == "wg-private-key")
        #expect(!s.isWiped)
        s.wipe()
        #expect(s.isWiped)
        #expect(s.utf8String() == nil)
        s.wipe()   // idempotent
    }

    @Test func consumingZeroesTheSource() {
        var source = Data("token-123".utf8)
        let s = SecureBytes(consuming: &source)
        #expect(source.isEmpty)
        #expect(s.withBytes { Data($0) } == Data("token-123".utf8))
    }

    @Test func zeroHelperClearsMemory() {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { p.deallocate() }
        p.initializeMemory(as: UInt8.self, repeating: 0xFF, count: 8)
        SecureBytes.zero(p, count: 8)
        #expect(UnsafeRawBufferPointer(start: p, count: 8).allSatisfy { $0 == 0 })
    }

    @Test func dataSecureWipeEmptiesInPlace() {
        var d = Data(repeating: 7, count: 64)
        d.secureWipe()
        #expect(d.isEmpty)
    }
}

@Suite struct VaultKeyTests {
    @Test func inMemoryKeyIsOnlyAvailableWhileUnlocked() async throws {
        let v = InMemoryVaultKey()
        await #expect(throws: VaultKeyError.locked) { try await v.key() }
        try await v.unlock(reason: "test")
        let k1 = try await v.key()
        await v.lock()
        #expect(await v.isUnlocked == false)
        await #expect(throws: VaultKeyError.locked) { try await v.key() }
        try await v.unlock(reason: "test")
        #expect(try await v.key() == k1)
    }

    @Test func refusedAuthenticationKeepsItLocked() async {
        let v = InMemoryVaultKey()
        await v.setAllowUnlock(false)
        await #expect(throws: VaultKeyError.authenticationFailed) { try await v.unlock(reason: "test") }
        #expect(await v.isUnlocked == false)
    }
}

@Suite struct ProcessHardeningTests {
    @Test func coreDumpsCanBeDisabled() {
        #expect(ProcessHardening.disableCoreDumps())
        var limit = rlimit()
        getrlimit(RLIMIT_CORE, &limit)
        #expect(limit.rlim_cur == 0)
    }

    /// Debug test builds skip deny-attach so the test runner (a debugger client) keeps working.
    @Test func debugBuildsDoNotDenyAttach() {
        let report = ProcessHardening.apply()
        #if DEBUG
        #expect(report.debuggerDenied == false)
        #endif
        #expect(report.coreDumpsDisabled)
    }
}
