import Foundation

/// Canvas/Context layout derived from available geometry (spec 5.3, 7.3).
public enum LayoutMode: Sendable, Equatable {
    case compact
    case wide(canvasFraction: Double)
    /// Folded like a laptop: Canvas on the upper half, Context on the lower half.
    case deskLike
    case duo(DuoPosture)

    public var showsContextAlongside: Bool {
        switch self {
        case .compact: false
        case .wide, .deskLike, .duo: true
        }
    }
}

public enum DuoPosture: Sendable, Equatable { case flat, partiallyFolded, closed }

public enum HingeOrientation: Sendable, Equatable { case vertical, horizontal }

public struct LayoutGeometry: Sendable, Equatable {
    public var width: Double
    public var height: Double
    /// Region covered by the hinge along the split axis, in points, if the OS reports one. Controls never go under it.
    public var hingeOcclusion: ClosedRange<Double>?
    public var hingeOrientation: HingeOrientation?
    public var posture: DuoPosture?

    public init(width: Double, height: Double, hingeOcclusion: ClosedRange<Double>? = nil,
                hingeOrientation: HingeOrientation? = nil, posture: DuoPosture? = nil) {
        self.width = width; self.height = height; self.hingeOcclusion = hingeOcclusion
        self.hingeOrientation = hingeOrientation; self.posture = posture
    }
}

/// Two non-overlapping panes along one axis. Lengths are in points along `axis`.
public struct PaneSplit: Sendable, Equatable {
    public enum Axis: Sendable, Equatable { case horizontal, vertical }
    public var axis: Axis
    public var canvas: ClosedRange<Double>
    public var context: ClosedRange<Double>
}

/// iPhone Duo support is required (ADR-011). Hinge and posture signals plug in through this protocol
/// once the iOS 27.2 SDK APIs are confirmed (ticket K-02). Until a signal source reports values,
/// layout falls back to geometry alone, which ADR-007 keeps as the baseline.
public protocol DeviceCapabilityProviding: Sendable {
    var supportsHingeObservation: Bool { get }
    var supportsSecondaryDisplayScene: Bool { get }
}

/// A source of hinge and posture readings. Implementations must use public APIs only (spec 7.3).
public protocol HingeSignalSource: Sendable {
    var isAvailable: Bool { get }
    func currentReading() async -> (posture: DuoPosture, occlusion: ClosedRange<Double>?, orientation: HingeOrientation)?
}

/// Default capability provider: geometry-based, with no hinge signal until one is registered.
public struct DuoCapabilityAdapter: DeviceCapabilityProviding {
    public let hinge: HingeSignalSource?
    public let secondaryDisplay: Bool
    public init(hinge: HingeSignalSource? = nil, secondaryDisplay: Bool = false) {
        self.hinge = hinge; self.secondaryDisplay = secondaryDisplay
    }
    public var supportsHingeObservation: Bool { hinge?.isAvailable ?? false }
    public var supportsSecondaryDisplayScene: Bool { secondaryDisplay }
}

public enum LayoutResolver {
    /// Minimum width in points for a side-by-side Canvas and Context.
    public static let wideThreshold: Double = 700
    public static let minimumPane: Double = 280

    public static func mode(for g: LayoutGeometry) -> LayoutMode {
        if let posture = g.posture {
            if posture == .partiallyFolded && g.hingeOrientation == .horizontal { return .deskLike }
            if posture == .closed { return .compact }
            return .duo(posture)
        }
        if g.width >= wideThreshold { return .wide(canvasFraction: 0.65) }
        return .compact
    }

    /// Splits the screen so neither pane sits under the hinge (spec 7.3). `fraction` is the Canvas share
    /// when there is no hinge; with a hinge, the split snaps to it.
    public static func split(for g: LayoutGeometry, fraction: Double = 0.65) -> PaneSplit? {
        let mode = mode(for: g)
        guard mode.showsContextAlongside else { return nil }
        let axis: PaneSplit.Axis = (mode == .deskLike || g.hingeOrientation == .horizontal) ? .vertical : .horizontal
        let length = axis == .horizontal ? g.width : g.height
        if let hinge = g.hingeOcclusion, hinge.lowerBound > 0, hinge.upperBound < length {
            return PaneSplit(axis: axis, canvas: 0...hinge.lowerBound, context: hinge.upperBound...length)
        }
        let f = min(0.8, max(0.35, fraction))
        var cut = (length * f).rounded()
        cut = min(max(cut, minimumPane), length - minimumPane)
        guard cut > 0, cut < length else { return nil }
        return PaneSplit(axis: axis, canvas: 0...cut, context: cut...length)
    }
}
