import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication

/// Face ID / Touch ID with device-passcode fallback (spec 7.4).
public struct BiometricAuthenticator: Authenticating {
    public init() {}

    public var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    public func authenticate(reason: String) async throws -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = nil
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            return false
        }
    }
}
#endif

/// Deterministic authenticator for tests and UI previews.
public struct StubAuthenticator: Authenticating {
    public var result: Bool
    public init(result: Bool) { self.result = result }
    public func authenticate(reason: String) async throws -> Bool { result }
}
