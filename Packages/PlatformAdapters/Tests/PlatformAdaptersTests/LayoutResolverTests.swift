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

    @Test func noHingeSignalByDefault() {
        #expect(!DuoCapabilityAdapter().supportsHingeObservation)
    }
}
