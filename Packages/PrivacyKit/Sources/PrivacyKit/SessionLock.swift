import Foundation
import Observation
import KageModels
import SecurityKit

/// Spec 7.4 lock triggers.
public struct LockTriggers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let appBackground = LockTriggers(rawValue: 1 << 0)
    public static let inactivity = LockTriggers(rawValue: 1 << 1)
    public static let deviceClose = LockTriggers(rawValue: 1 << 2)   // only where the OS reports it
    public static let deviceLock = LockTriggers(rawValue: 1 << 3)    // protected-data-unavailable notification
    public static let manual = LockTriggers(rawValue: 1 << 4)
}

/// Conceals content first, then runs any cleanup the lock mode asks for (spec 7.4, AT10).
/// Concealment is synchronous on the main actor so it lands well inside the 250 ms target.
@MainActor @Observable
public final class SessionLockCoordinator {
    public private(set) var isLocked = false
    /// True whenever web content and previews must be hidden: locked, or briefly inactive (app switcher snapshot).
    public private(set) var isConcealed = false
    public private(set) var lastCleanupMessage: String?
    public private(set) var isCleaning = false

    public var mode: LockPolicy
    public var triggers: LockTriggers
    public var inactivityTimeout: Duration
    public var isEnabled: Bool { mode != .none }

    @ObservationIgnored private let authenticator: Authenticating
    @ObservationIgnored private let cleanup: @Sendable (LockPolicy) async -> String?
    @ObservationIgnored private var inactivityTask: Task<Void, Never>?
    /// Runs synchronously right after concealment, on every lock: the app shell releases web content,
    /// snapshots, caches and the Vault key here (threat model T-11).
    @ObservationIgnored public var onLock: (@MainActor () -> Void)?
    /// Runs after a successful unlock.
    @ObservationIgnored public var onUnlock: (@MainActor () -> Void)?

    public init(mode: LockPolicy = .none, triggers: LockTriggers = [.appBackground, .manual],
                inactivityTimeout: Duration = .seconds(300), authenticator: Authenticating,
                cleanup: @escaping @Sendable (LockPolicy) async -> String? = { _ in nil }) {
        self.mode = mode; self.triggers = triggers; self.inactivityTimeout = inactivityTimeout
        self.authenticator = authenticator; self.cleanup = cleanup
    }

    /// Locks now. Returns after concealment; cleanup continues asynchronously and reports when it finishes.
    @discardableResult
    public func lock(trigger: LockTriggers = .manual) -> Task<Void, Never>? {
        guard isEnabled, triggers.contains(trigger) || trigger == .manual else { return nil }
        isConcealed = true
        isLocked = true
        inactivityTask?.cancel()
        onLock?()
        let mode = self.mode
        guard mode == .lockAndForget || mode == .lockAndDestroyTemporary else { return nil }
        isCleaning = true
        lastCleanupMessage = nil
        return Task { [weak self] in
            let message = await self?.cleanup(mode)
            self?.isCleaning = false
            self?.lastCleanupMessage = message
        }
    }

    public func unlock(reason: String = "Unlock Kage") async -> Bool {
        let ok = (try? await authenticator.authenticate(reason: reason)) ?? false
        if ok {
            isLocked = false
            isConcealed = false
            noteActivity()
            onUnlock?()
        }
        return ok
    }

    // MARK: Lifecycle hooks, called by the app shell

    /// Scene is about to become inactive: hide content before the system takes its snapshot.
    public func sceneWillResignActive() {
        guard isEnabled else { return }
        isConcealed = true
    }

    public func sceneDidEnterBackground() { lock(trigger: .appBackground) }
    public func deviceDidLock() { lock(trigger: .deviceLock) }
    public func deviceDidClose() { lock(trigger: .deviceClose) }

    public func sceneDidBecomeActive() {
        if !isLocked { isConcealed = false; noteActivity() }
    }

    public func noteActivity() {
        guard isEnabled, triggers.contains(.inactivity), !isLocked else { return }
        inactivityTask?.cancel()
        let timeout = inactivityTimeout
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.lock(trigger: .inactivity)
        }
    }
}
