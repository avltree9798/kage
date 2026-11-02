#if canImport(SwiftUI)
import SwiftUI

/// Graphite surfaces, restrained type, optional accent (spec 5.4).
/// Colours meet contrast in light and dark mode; privacy state is never shown by colour alone (spec 17).
public enum KageTokens {
    public static let spacing: CGFloat = 8
    public static let cornerRadius: CGFloat = 10
    public static let canvasFraction: CGFloat = 0.65
    public static let graphite = Color(white: 0.16)
    /// The tab sidebar's surface (always dark, so profile tints read the same in light and dark mode).
    public static let sidebarGraphite = Color(red: 0.086, green: 0.094, blue: 0.114)
    /// Fields on the sidebar (the address field on Mac and iPad), #23262D.
    public static let sidebarField = Color(red: 0.137, green: 0.149, blue: 0.176)

    #if os(iOS)
    public static let chromeBackground = Color(uiColor: .secondarySystemBackground)
    public static let fieldBackground = Color(uiColor: .tertiarySystemFill)
    public static let panelBackground = Color(uiColor: .systemGroupedBackground)
    #else
    public static let chromeBackground = Color(nsColor: .windowBackgroundColor)
    public static let fieldBackground = Color(nsColor: .controlBackgroundColor)
    public static let panelBackground = Color(nsColor: .underPageBackgroundColor)
    #endif

    public static let accents: [String: Color] = [
        "indigo": .indigo, "teal": .teal, "red": .red, "orange": .orange, "graphite": .gray, "green": .green,
    ]

    /// Tint per profile; always paired with the profile's name in the UI.
    public static func profileTint(_ kindRawValue: String) -> Color {
        switch kindRawValue {
        case "ghost": .purple
        case "vault": .teal
        case "private": .gray
        default: .accentColor
        }
    }
}

/// Small rounded label used for profile and status chips.
public struct KageChip: View {
    let text: String
    let systemImage: String?
    let tint: Color
    public init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text; self.systemImage = systemImage; self.tint = tint
    }
    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
#endif
