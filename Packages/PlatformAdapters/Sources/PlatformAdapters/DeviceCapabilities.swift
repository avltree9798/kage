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

/// iPhone Duo support is required (ADR-011). The iOS 27.1+ SDK reports the fold through two public APIs,
/// confirmed against the iOS 27.2 SDK on 2026-11-01 (ticket K-02):
/// - `View.onHingeChange(isEnabled:_:)` delivers `DeviceHingeContext.hinge: DeviceHinge?`
///   (`status` is `.closed`, `.partiallyOpen` or `.fullyOpen`; `angle` is an `Angle`; `nil` means no hinge).
/// - `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)` returns `ReservedRegion`s of kind
///   `.division` (where the screen is split by the fold) or `.occlusion` (where content is hidden), with
///   `frame`, `margins` and `isActive`.
/// The SwiftUI layer reads those and passes plain values here, so layout logic stays testable everywhere.
public protocol DeviceCapabilityProviding: Sendable {
    var supportsHingeObservation: Bool { get }
    var supportsSecondaryDisplayScene: Bool { get }
}

/// Plain mirror of `DeviceHinge.Status`.
public enum HingeStatus: Sendable, Equatable { case closed, partiallyOpen, fullyOpen }

/// Plain mirror of an active `ReservedRegion` frame, in the root view's coordinate space.
public struct ReservedRegionReading: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case division, occlusion }
    public var kind: Kind
    public var x: Double, y: Double, width: Double, height: Double
    public var isActive: Bool
    public init(kind: Kind, x: Double, y: Double, width: Double, height: Double, isActive: Bool = true) {
        self.kind = kind; self.x = x; self.y = y; self.width = width; self.height = height; self.isActive = isActive
    }
}

public enum DuoSignals {
    public static func posture(for status: HingeStatus?) -> DuoPosture? {
        switch status {
        case nil: nil
        case .closed: .closed
        case .partiallyOpen: .partiallyFolded
        case .fullyOpen: .flat
        }
    }

    /// Builds layout geometry from the hinge status and the reserved regions SwiftUI reports. The fold's
    /// orientation comes from the region's shape: a tall strip is a vertical hinge (panes side by side),
    /// a wide strip is a horizontal hinge (panes stacked). Occlusion wins over division, because content
    /// under an occluded strip can't be seen at all. Inactive regions (e.g. the fold while closed) are ignored.
    public static func geometry(width: Double, height: Double, hinge: HingeStatus?,
                                regions: [ReservedRegionReading]) -> LayoutGeometry {
        let active = regions.filter { $0.isActive && $0.width >= 0 && $0.height >= 0 }
        let region = active.first { $0.kind == .occlusion } ?? active.first { $0.kind == .division }
        var g = LayoutGeometry(width: width, height: height, posture: posture(for: hinge))
        guard let r = region else {
            // A hinge without a reported region (e.g. folded shut, or a single-panel window) has no split.
            if g.posture != nil, g.posture != .closed { g.hingeOrientation = width >= height ? .vertical : .horizontal }
            return g
        }
        if r.height >= r.width {
            g.hingeOrientation = .vertical
            g.hingeOcclusion = r.x...(r.x + r.width)
        } else {
            g.hingeOrientation = .horizontal
            g.hingeOcclusion = r.y...(r.y + r.height)
        }
        // A reported division without hinge status still means two panels (e.g. an external display mirror).
        if g.posture == nil { g.posture = .flat }
        return g
    }
}

/// Capability provider. On iOS the hinge API exists on every device from iOS 27.1, and reports `nil`
/// on phones without a fold; `hingeObserved` flips once SwiftUI delivers a non-nil hinge.
public struct DuoCapabilityAdapter: DeviceCapabilityProviding {
    public let hingeObserved: Bool
    public let secondaryDisplay: Bool
    public init(hingeObserved: Bool = false, secondaryDisplay: Bool = false) {
        self.hingeObserved = hingeObserved; self.secondaryDisplay = secondaryDisplay
    }
    public var supportsHingeObservation: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
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
