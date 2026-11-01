import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A fixed-size buffer for secrets (tokens, keys, decrypted tunnel configs) that is locked out of swap,
/// never copied by Swift's copy-on-write, and zeroed with `memset_s` (which the compiler can't elide)
/// as soon as it's wiped or released. It narrows how long a secret sits in memory; it can't hide it
/// from a process with root while it's in use.
public final class SecureBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: UnsafeMutableRawPointer?
    public let count: Int

    public init(count: Int) {
        self.count = count
        let p = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        p.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1))
        #if canImport(Darwin)
        mlock(p, max(count, 1))
        #endif
        pointer = p
    }

    /// Copies `bytes` in and then zeroes the caller's copy.
    public convenience init(consuming bytes: inout Data) {
        self.init(count: bytes.count)
        bytes.withUnsafeBytes { src in
            if let base = src.baseAddress { pointer?.copyMemory(from: base, byteCount: count) }
        }
        bytes.secureWipe()
    }

    public convenience init(_ bytes: [UInt8]) {
        var d = Data(bytes)
        self.init(consuming: &d)
    }

    public var isWiped: Bool { lock.withLock { pointer == nil } }

    /// Runs `body` with the bytes; returns nil once wiped.
    public func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        try lock.withLock {
            guard let p = pointer else { return nil }
            return try body(UnsafeRawBufferPointer(start: p, count: count))
        }
    }

    /// The bytes as UTF-8 text. The returned String is an ordinary copy, so callers keep its lifetime short.
    public func utf8String() -> String? { withBytes { String(decoding: $0, as: UTF8.self) } }

    public func wipe() {
        lock.withLock {
            guard let p = pointer else { return }
            SecureBytes.zero(p, count: max(count, 1))
            #if canImport(Darwin)
            munlock(p, max(count, 1))
            #endif
            p.deallocate()
            pointer = nil
        }
    }

    deinit { wipe() }

    static func zero(_ p: UnsafeMutableRawPointer, count: Int) {
        #if canImport(Darwin)
        _ = memset_s(p, count, 0, count)
        #else
        p.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        #endif
    }
}

public extension Data {
    /// Zeroes this buffer in place. Earlier copies made by copy-on-write aren't reachable and aren't wiped,
    /// so wipe as close to where the data was produced as possible.
    mutating func secureWipe() {
        let n = count
        guard n > 0 else { return }
        withUnsafeMutableBytes { buf in
            if let base = buf.baseAddress { SecureBytes.zero(base, count: n) }
        }
        removeAll()
    }
}
