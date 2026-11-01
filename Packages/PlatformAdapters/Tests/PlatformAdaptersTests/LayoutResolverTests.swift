import Testing
@testable import PlatformAdapters

@Suite struct LayoutResolverTests {
    @Test func layoutModes() {
        #expect(LayoutResolver.mode(for: .init(width: 390, height: 844)) == .compact)
        #expect(LayoutResolver.mode(for: .init(width: 1024, height: 768)) == .wide(canvasFraction: 0.65))
        #expect(LayoutResolver.mode(for: .init(width: 800, height: 600, posture: .flat)) == .duo(.flat))
        #expect(LayoutResolver.mode(for: .init(width: 800, height: 900, hingeOrientation: .horizontal, posture: .partiallyFolded)) == .deskLike)
        #expect(LayoutResolver.mode(for: .init(width: 400, height: 800, posture: .closed)) == .compact)
    }

    // AT11 groundwork: panes avoid the hinge.
    @Test func splitAvoidsHinge() {
        let g = LayoutGeometry(width: 900, height: 700, hingeOcclusion: 440...460, hingeOrientation: .vertical, posture: .flat)
        let s = LayoutResolver.split(for: g)
        #expect(s?.canvas == 0...440)
        #expect(s?.context == 460...900)
        #expect(s?.axis == .horizontal)
    }

    @Test func splitWithoutHingeRespectsMinimumPane() {
        let s = LayoutResolver.split(for: .init(width: 800, height: 600), fraction: 0.95)
        #expect(s?.canvas.upperBound == 520)
        #expect(LayoutResolver.split(for: .init(width: 390, height: 844)) == nil)
    }

    @Test func hingeObservationOnlyOnIOS() {
        #if os(iOS)
        #expect(DuoCapabilityAdapter().supportsHingeObservation)
        #else
        #expect(!DuoCapabilityAdapter().supportsHingeObservation)
        #endif
    }

    // K-02: mapping of the iOS 27.1+ hinge and reserved-region signals.
    @Test func noHingeMeansGeometryOnly() {
        let g = DuoSignals.geometry(width: 390, height: 844, hinge: nil, regions: [])
        #expect(g == LayoutGeometry(width: 390, height: 844))
        #expect(LayoutResolver.mode(for: g) == .compact)
    }

    @Test func openDuoWithVerticalFoldSplitsAroundIt() {
        let fold = ReservedRegionReading(kind: .division, x: 410, y: 0, width: 20, height: 900)
        let g = DuoSignals.geometry(width: 840, height: 900, hinge: .fullyOpen, regions: [fold])
        #expect(g.posture == .flat)
        #expect(g.hingeOrientation == .vertical)
        #expect(LayoutResolver.mode(for: g) == .duo(.flat))
        let s = LayoutResolver.split(for: g)
        #expect(s?.axis == .horizontal)
        #expect(s?.canvas == 0...410)
        #expect(s?.context == 430...840)
    }

    @Test func halfFoldedWithHorizontalFoldIsDeskLike() {
        let fold = ReservedRegionReading(kind: .division, x: 0, y: 440, width: 900, height: 0)
        let g = DuoSignals.geometry(width: 900, height: 880, hinge: .partiallyOpen, regions: [fold])
        #expect(g.hingeOrientation == .horizontal)
        #expect(LayoutResolver.mode(for: g) == .deskLike)
        let s = LayoutResolver.split(for: g, fraction: 0.5)
        #expect(s?.axis == .vertical)
        #expect(s?.canvas == 0...440)
    }

    @Test func occlusionWinsAndInactiveRegionsAreIgnored() {
        let division = ReservedRegionReading(kind: .division, x: 420, y: 0, width: 0, height: 900)
        let occlusion = ReservedRegionReading(kind: .occlusion, x: 400, y: 0, width: 40, height: 900)
        let stale = ReservedRegionReading(kind: .occlusion, x: 0, y: 0, width: 10, height: 900, isActive: false)
        let g = DuoSignals.geometry(width: 840, height: 900, hinge: .fullyOpen, regions: [stale, division, occlusion])
        #expect(g.hingeOcclusion == 400...440)
    }

    @Test func closedDuoIsCompact() {
        let g = DuoSignals.geometry(width: 390, height: 844, hinge: .closed, regions: [])
        #expect(LayoutResolver.mode(for: g) == .compact)
        #expect(LayoutResolver.split(for: g) == nil)
    }
}
