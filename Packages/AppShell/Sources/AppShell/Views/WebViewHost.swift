#if canImport(WebKit)
import SwiftUI
import WebKit

/// Hosts whichever `WKWebView` belongs to the active tab, swapping it in place so tab
/// switches don't rebuild the SwiftUI tree (spec 16: active-tab switch under 150 ms).
#if os(iOS)
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .systemBackground
        return v
    }

    func updateUIView(_ container: UIView, context: Context) {
        if let current = container.subviews.first as? WKWebView, current === webView { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
#else
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        if let current = container.subviews.first as? WKWebView, current === webView { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
#endif

extension View {
    /// Applies inline navigation titles on iOS only.
    @ViewBuilder func kageInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

enum Clipboard {
    @MainActor static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}
#endif
