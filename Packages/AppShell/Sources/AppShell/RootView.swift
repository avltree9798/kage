#if canImport(SwiftUI)
import SwiftUI
import DesignSystem
import PlatformAdapters

/// Placeholder Canvas/Context shell. Real chrome arrives in K-07 and K-27.
public struct RootView: View {
    public init() {}
    public var body: some View {
        GeometryReader { proxy in
            let mode = LayoutResolver.mode(for: .init(width: proxy.size.width, height: proxy.size.height))
            HStack(spacing: 0) {
                Text("Canvas").frame(maxWidth: .infinity, maxHeight: .infinity)
                if case .wide = mode {
                    Divider()
                    Text("Context").frame(width: proxy.size.width * (1 - KageTokens.canvasFraction))
                }
            }
        }
    }
}
#endif
