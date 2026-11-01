import Testing
@testable import PlatformAdapters

@Test func layoutModes() {
    #expect(LayoutResolver.mode(for: .init(width: 390, height: 844)) == .compact)
    #expect(LayoutResolver.mode(for: .init(width: 1024, height: 768)) == .wide(canvasFraction: 0.65))
    #expect(LayoutResolver.mode(for: .init(width: 800, height: 600, posture: .partiallyFolded)) == .duo(.partiallyFolded))
}
