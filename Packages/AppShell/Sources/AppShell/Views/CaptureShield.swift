import SwiftUI
import KageModels
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Threat model T-14: what's on screen. On iOS, page content is covered while the screen is recorded,
/// mirrored or sent over AirPlay (always in Private and Vault, everywhere with the setting on).
/// On macOS the window is excluded from screenshots and screen sharing that honour `NSWindow.sharingType`.
struct CaptureShield: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    var shouldHide: Bool {
        env.settings.hideFromScreenCapture || env.currentKind == .vault || env.currentKind == .private
    }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background { CaptureStateReader { env.screenIsCaptured = $0 }.accessibilityHidden(true) }
            .overlay {
                if shouldHide && env.screenIsCaptured {
                    ZStack {
                        Rectangle().fill(.background).ignoresSafeArea()
                        Label("Hidden while the screen is shared", systemImage: "eye.slash")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            #elseif os(macOS)
            .background { WindowSharingSetter(hidden: shouldHide).accessibilityHidden(true) }
            #endif
    }
}

#if os(iOS)
/// Reports the window scene's capture state (recording, mirroring, AirPlay).
struct CaptureStateReader: UIViewRepresentable {
    let onChange: @MainActor (Bool) -> Void
    func makeUIView(context: Context) -> CaptureProbeView {
        let v = CaptureProbeView()
        v.onChange = onChange
        return v
    }
    func updateUIView(_ view: CaptureProbeView, context: Context) { view.onChange = onChange }
}

final class CaptureProbeView: UIView {
    var onChange: (@MainActor (Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        registerForTraitChanges([UITraitSceneCaptureState.self]) { (view: CaptureProbeView, _: UITraitCollection) in
            view.report()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func didMoveToWindow() { super.didMoveToWindow(); report() }
    func report() {
        let captured = traitCollection.sceneCaptureState == .active
        DispatchQueue.main.async { [onChange] in onChange?(captured) }
    }
}
#elseif os(macOS)
/// Sets the hosting window's sharing type. Some capture tools ignore it; the threat model says so.
struct WindowSharingSetter: NSViewRepresentable {
    let hidden: Bool
    func makeNSView(context: Context) -> NSView { SharingProbe() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? SharingProbe)?.hidden = hidden
    }
    final class SharingProbe: NSView {
        var hidden = false { didSet { apply() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() { window?.sharingType = hidden ? .none : .readOnly }
    }
}
#endif
