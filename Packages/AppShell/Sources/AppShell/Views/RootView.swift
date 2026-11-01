#if canImport(WebKit)
import SwiftUI
import KageModels
import PlatformAdapters
import DesignSystem

/// Root of every window: picks Compact, Wide, Desk-like or Duo layout from geometry (spec 5.3, 7.3)
/// and keeps the selected tab across every change (AT11).
public struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var contextFraction: Double = KageTokens.canvasFraction
    @State private var showContextSheet = false
    @State private var destination: Destination?

    enum Destination: String, Identifiable { case library, privacy, settings; var id: String { rawValue } }

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let geometry = LayoutGeometry(width: proxy.size.width, height: proxy.size.height)
            let mode = LayoutResolver.mode(for: geometry)
            content(mode: mode, geometry: geometry)
                .onChange(of: mode) { _, new in
                    // Geometry changed (rotation, fold, resize): the active tab is untouched; only panes move.
                    if !new.showsContextAlongside && env.isContextVisible { showContextSheet = false }
                }
        }
        .overlay { if env.lock.isConcealed { LockOverlayView() } }
        .modifier(PromptHost())
        .sheet(isPresented: $showContextSheet) { ContextPanel().environment(env).presentationDetents([.medium, .large]) }
        .sheet(item: $destination) { d in
            NavigationStack {
                switch d {
                case .library: LibraryView()
                case .privacy: PrivacyDashboardView()
                case .settings: SettingsView()
                }
            }
            .environment(env)
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 520)
            #endif
        }
        .sheet(isPresented: Binding(get: { !env.settings.onboardingComplete }, set: { _ in })) {
            OnboardingView().environment(env).interactiveDismissDisabled()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive: env.lock.sceneWillResignActive()
            case .background:
                env.lock.sceneDidEnterBackground()
                Task { await env.currentStore.persist(); await env.runCleanup(.background) }
            case .active:
                env.lock.sceneDidBecomeActive()
                Task { await env.runCleanup(.foreground) }
            @unknown default: break
            }
        }
        .task { await env.start() }
        .simultaneousGesture(TapGesture().onEnded { env.lock.noteActivity() })
    }

    @ViewBuilder
    private func content(mode: LayoutMode, geometry: LayoutGeometry) -> some View {
        VStack(spacing: 0) {
            switch mode {
            case .compact:
                CanvasView()
                compactBar
            case .wide, .duo:
                if env.isContextVisible, let split = LayoutResolver.split(for: geometry, fraction: contextFraction) {
                    HStack(spacing: 0) {
                        CanvasView().frame(width: split.canvas.upperBound - split.canvas.lowerBound)
                        divider(total: geometry.width)
                        // Leave the hinge region empty so no control sits under it (spec 7.3).
                        if split.context.lowerBound > split.canvas.upperBound {
                            Color.clear.frame(width: split.context.lowerBound - split.canvas.upperBound)
                        }
                        ContextPanel()
                    }
                } else {
                    CanvasView()
                }
                destinationBar
            case .deskLike:
                if let split = LayoutResolver.split(for: geometry, fraction: 0.5) {
                    CanvasView().frame(height: split.canvas.upperBound - split.canvas.lowerBound)
                    Divider()
                    ContextPanel()
                } else {
                    CanvasView()
                }
            }
        }
    }

    private func divider(total: Double) -> some View {
        Rectangle().fill(.separator).frame(width: 1)
            .overlay(Color.clear.frame(width: 12).contentShape(Rectangle()))
            .gesture(DragGesture().onChanged { v in
                contextFraction = min(0.8, max(0.35, (v.location.x + total * contextFraction) / total))
            })
            .accessibilityLabel("Resize Context panel")
            .accessibilityAdjustableAction { dir in
                contextFraction = min(0.8, max(0.35, contextFraction + (dir == .increment ? 0.05 : -0.05)))
            }
    }

    private var compactBar: some View {
        HStack {
            Button { showContextSheet = true } label: { Label("Context", systemImage: "sparkles.rectangle.stack") }
            Spacer()
            destinationButtons
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(KageTokens.chromeBackground)
    }

    private var destinationBar: some View {
        HStack { Spacer(); destinationButtons }
            .labelStyle(.titleAndIcon).buttonStyle(.borderless).font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(KageTokens.chromeBackground)
    }

    private var destinationButtons: some View {
        HStack(spacing: 18) {
            Button { destination = .library } label: { Label("Library", systemImage: "books.vertical") }
            Button { destination = .privacy } label: { Label("Privacy", systemImage: "hand.raised") }
            Button { destination = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Covers everything, including previews in the app switcher, until the user authenticates (AT10).
struct LockOverlayView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                Text("Kage is locked").font(.title2.weight(.semibold))
                if env.lock.isCleaning { ProgressView("Clearing temporary records…") }
                if let msg = env.lock.lastCleanupMessage { Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if env.lock.isLocked {
                    Button("Unlock") { Task { failed = !(await env.lock.unlock()) } }.buttonStyle(.borderedProminent)
                    if failed { Text("Authentication didn't succeed.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .padding()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Renders page-originated prompts, always naming the site that asked (spec 15.2).
struct PromptHost: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        @Bindable var prompts = env.prompts
        let pending = prompts.pending
        return content.alert(title(pending?.kind), isPresented: Binding(get: { pending != nil }, set: { if !$0 && prompts.pending != nil { prompts.answer(.cancel) } }), presenting: pending) { p in
            switch p.kind {
            case .alert:
                Button("OK") { prompts.answer(.ok) }
            case .confirm, .openExternal:
                Button("Cancel", role: .cancel) { prompts.answer(.cancel) }
                Button("OK") { prompts.answer(.ok) }
            case .prompt:
                TextField("", text: $prompts.promptText)
                Button("Cancel", role: .cancel) { prompts.answer(.text(nil)) }
                Button("OK") { prompts.answer(.text(prompts.promptText)) }
            case .media:
                Button("Don't Allow", role: .cancel) { prompts.answer(.decision(.deny)) }
                Button("Allow Once") { prompts.answer(.decision(.allow)) }
            }
        } message: { p in
            switch p.kind {
            case .alert(let m, _), .confirm(let m, _), .prompt(let m, _, _): Text(m)
            case .openExternal(let url): Text("Open \(url.scheme ?? "this link") link in another app?")
            case .media(_, let cam, let mic): Text("Use your \([cam ? "camera" : nil, mic ? "microphone" : nil].compactMap { $0 }.joined(separator: " and "))?")
            }
        }
    }

    private func title(_ k: PromptCenter.Kind?) -> String {
        switch k {
        case .alert(_, let h), .confirm(_, let h), .prompt(_, _, let h): "\(h) says"
        case .openExternal: "Leave Kage?"
        case .media(let h, _, _): "\(h) wants access"
        case nil: ""
        }
    }
}
#endif
