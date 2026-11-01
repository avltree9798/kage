import Foundation

/// Canvas/Context layout derived from available geometry (spec 5.3, 7.3).
public enum LayoutMode: Sendable, Equatable {
    case compact
    case wide(canvasFraction: Double)
    case deskLike
    case duo(DuoPosture)
}

public enum DuoPosture: Sendable, Equatable { case flat, partiallyFolded, closed }

public struct LayoutGeometry: Sendable, Equatable {
    public var width: Double
    public var height: Double
    /// Region covered by the hinge, in points, if the OS reports one. Controls never go under it.
    public var hingeOcclusion: ClosedRange<Double>?
    public var posture: DuoPosture?
    public init(width: Double, height: Double, hingeOcclusion: ClosedRange<Double>? = nil, posture: DuoPosture? = nil) {
        self.width = width; self.height = height; self.hingeOcclusion = hingeOcclusion; self.posture = posture
    }
}

/// iPhone Duo support is required (decided 2026-11-01). The concrete Duo adapter is written once
/// the iOS 27.2 SDK APIs are confirmed in ticket K-02; until then these flags stay capability-gated.
public protocol DeviceCapabilityProviding: Sendable {
    var supportsHingeObservation: Bool { get }
    var supportsSecondaryDisplayScene: Bool { get }
    var geometry: AsyncStream<LayoutGeometry> { get }
}

public enum LayoutResolver {
    /// Minimum width in points for a side-by-side Canvas and Context.
    public static let wideThreshold: Double = 700

    public static func mode(for g: LayoutGeometry) -> LayoutMode {
        if let posture = g.posture { return .duo(posture) }
        if g.width >= wideThreshold { return .wide(canvasFraction: 0.65) }
        return .compact
    }
}
