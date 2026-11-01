import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Release-build process hardening (threat model T-12). It raises the cost of casual inspection; it does
/// not stop an attacker with root, who can patch any of it out. Debug builds skip it so Xcode can attach.
public enum ProcessHardening {
    public struct Report: Sendable, Equatable {
        public var debuggerDenied: Bool
        public var coreDumpsDisabled: Bool
        public var debuggerAttached: Bool
    }

    /// Call once at launch, before any secret is loaded.
    @discardableResult
    public static func apply() -> Report {
        #if DEBUG
        return Report(debuggerDenied: false, coreDumpsDisabled: disableCoreDumps(), debuggerAttached: isDebuggerAttached())
        #else
        return Report(debuggerDenied: denyDebuggerAttach(), coreDumpsDisabled: disableCoreDumps(), debuggerAttached: isDebuggerAttached())
        #endif
    }

    /// No core files: a crash must not write page contents or keys to disk.
    public static func disableCoreDumps() -> Bool {
        #if canImport(Darwin)
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        return setrlimit(RLIMIT_CORE, &limit) == 0
        #else
        return false
        #endif
    }

    /// `ptrace(PT_DENY_ATTACH)`: later debugger attaches fail. `ptrace` isn't in the iOS SDK headers,
    /// so it's looked up at runtime.
    public static func denyDebuggerAttach() -> Bool {
        #if canImport(Darwin)
        typealias PtraceFn = @convention(c) (CInt, pid_t, UnsafeMutableRawPointer?, CInt) -> CInt
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "ptrace") else { return false }
        let ptrace = unsafeBitCast(sym, to: PtraceFn.self)
        let PT_DENY_ATTACH: CInt = 31
        return ptrace(PT_DENY_ATTACH, 0, nil, 0) == 0
        #else
        return false
        #endif
    }

    /// True when a debugger is attached now (`P_TRACED`).
    public static func isDebuggerAttached() -> Bool {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #else
        return false
        #endif
    }
}
