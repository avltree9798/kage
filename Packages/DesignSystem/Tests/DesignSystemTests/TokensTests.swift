import Testing
@testable import DesignSystem

#if canImport(SwiftUI)
@Test func canvasFractionMatchesSpec() {
    #expect(KageTokens.canvasFraction == 0.65)
}
#endif
