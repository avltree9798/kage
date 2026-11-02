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
    @State private var showSidebarSheet = false
    /// Last hinge status from `onHingeChange` (iOS 27.1+); `nil` on devices without a fold.
    @State private var hinge: HingeStatus?

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let geometry = DuoSignals.geometry(width: proxy.size.width, height: proxy.size.height,
                                               hinge: hinge, regions: Self.reservedRegions(proxy))
            let mode = LayoutResolver.mode(for: geometry)
            content(mode: mode, geometry: geometry)
                .onChange(of: mode) { _, new in
                    // Geometry changed (rotation, fold, resize): the active tab is untouched; only panes move.
                    if !new.showsContextAlongside && env.isContextVisible { showContextSheet = false }
                }
        }
        #if os(iOS)
        .onHingeChange { _, context in
            hinge = context.hinge.map { h in
                if h.status == .closed { return .closed }
                if h.status == .partiallyOpen { return .partiallyOpen }
                return .fullyOpen
            }
        }
        #endif
        .modifier(CaptureShield())
        .overlay { if env.lock.isConcealed { LockOverlayView() } }
        .modifier(PromptHost())
        .sheet(isPresented: $showContextSheet) { ContextPanel().environment(env).presentationDetents([.medium, .large]) }
        .sheet(item: Binding(get: { env.destination }, set: { env.destination = $0 })) { d in
            NavigationStack {
                switch d {
                case .library: LibraryView()
                case .privacy: PrivacyDashboardView()
                case .settings: SettingsView()
                }
            }
            .environment(env)
            .formStyle(.grouped)
            #if os(macOS)
            .frame(minWidth: 620, idealWidth: 680, minHeight: 600, idealHeight: 720)
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
                // The Vault never stays open in the background, whatever the lock setting (threat model T-11).
                env.lockVault()
            case .active:
                env.lock.sceneDidBecomeActive()
                Task { await env.runCleanup(.foreground) }
            @unknown default: break
            }
        }
        .task { await env.start() }
        .simultaneousGesture(TapGesture().onEnded { env.lock.noteActivity() })
        // The activity-tracking gesture makes the root an interactive group; name it so assistive tech can (K-30).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kage")
    }

    @ViewBuilder
    private func content(mode: LayoutMode, geometry: LayoutGeometry) -> some View {
        switch mode {
        case .compact:
            CanvasView(style: .compact, onTabs: { showSidebarSheet = true }, onContext: { showContextSheet = true })
                .modifier(SidebarCover(isPresented: $showSidebarSheet))
        case .wide:
            HStack(spacing: 0) {
                if env.isSidebarVisible {
                    SidebarView(showsAddress: true).frame(width: 280)
                        .transition(.move(edge: .leading))
                }
                canvasAndContext(geometry: geometry)
            }
        case .duo:
            // Page on the first screen; the second screen switches between Tabs and Context.
            if let split = LayoutResolver.split(for: geometry, fraction: 0.5) {
                let gap = split.context.lowerBound - split.canvas.upperBound
                let canvasLength = split.canvas.upperBound - split.canvas.lowerBound
                if split.axis == .horizontal {
                    HStack(spacing: 0) {
                        CanvasView(style: .compact, showsTabsButton: false, showsContextButton: false).frame(width: canvasLength)
                        Color.clear.frame(width: max(gap, 0)).accessibilityHidden(true)
                        DuoSecondaryPane()
                    }
                } else {
                    VStack(spacing: 0) {
                        CanvasView(style: .compact, showsTabsButton: false, showsContextButton: false).frame(height: canvasLength)
                        Color.clear.frame(height: max(gap, 0)).accessibilityHidden(true)
                        DuoSecondaryPane()
                    }
                }
            } else {
                CanvasView(style: .compact, onTabs: { showSidebarSheet = true }, onContext: { showContextSheet = true })
                    .modifier(SidebarCover(isPresented: $showSidebarSheet))
            }
        case .deskLike:
            VStack(spacing: 0) {
                if let split = LayoutResolver.split(for: geometry, fraction: 0.5) {
                    let gap = split.context.lowerBound - split.canvas.upperBound
                    CanvasView(style: .compact, showsContextButton: false, onTabs: { showSidebarSheet = true })
                        .frame(height: split.canvas.upperBound - split.canvas.lowerBound)
                    if gap > 0 { Color.clear.frame(height: gap).accessibilityHidden(true) } else { Divider() }
                    ContextPanel()
                } else {
                    CanvasView(style: .compact, onTabs: { showSidebarSheet = true }, onContext: { showContextSheet = true })
                }
            }
            .modifier(SidebarCover(isPresented: $showSidebarSheet))
        }
    }

    /// The page and, when shown, the Context panel beside it (wide windows).
    @ViewBuilder
    private func canvasAndContext(geometry: LayoutGeometry) -> some View {
        let canvas = CanvasView(style: .toolbar, showsOmnibox: !env.isSidebarVisible,
                                onTabs: { withAnimation(.snappy) { env.isSidebarVisible.toggle() } })
        if env.isContextVisible, let split = LayoutResolver.split(for: geometry, fraction: contextFraction) {
            let canvasLength = split.canvas.upperBound - split.canvas.lowerBound
            if split.axis == .horizontal {
                // The sidebar takes its width from the page, so the panel keeps its share of the rest.
                HStack(spacing: 0) {
                    canvas.frame(minWidth: 320, idealWidth: canvasLength, maxWidth: .infinity)
                    divider(total: geometry.width)
                    ContextPanel().frame(minWidth: 280, maxWidth: max(280, geometry.width - canvasLength))
                }
            } else {
                VStack(spacing: 0) {
                    canvas.frame(height: canvasLength)
                    Divider()
                    ContextPanel()
                }
            }
        } else {
            canvas
        }
    }

    /// Active fold regions in this view's space (iOS 27.1+ `GeometryProxy.reservedRegions`).
    static func reservedRegions(_ proxy: GeometryProxy) -> [ReservedRegionReading] {
        #if os(iOS)
        let pairs: [(ReservedRegion.Kind, ReservedRegionReading.Kind)] = [(.division, .division), (.occlusion, .occlusion)]
        return pairs.flatMap { kind, mapped in
            proxy.reservedRegions(kind: kind).map { r in
                ReservedRegionReading(kind: mapped, x: r.frame.minX, y: r.frame.minY,
                                      width: r.frame.width, height: r.frame.height, isActive: r.isActive)
            }
        }
        #else
        return []
        #endif
    }

    private func divider(total: Double) -> some View {
        Rectangle().fill(.separator).frame(width: 1)
            .overlay(Color.clear.frame(width: 12).contentShape(Rectangle()))
            .gesture(DragGesture().onChanged { v in
                contextFraction = min(0.8, max(0.35, (v.location.x + total * contextFraction) / total))
            })
            // Exposed as a slider so assistive tech knows its role (K-30 audit: "Unknown role").
            .accessibilityRepresentation {
                Slider(value: $contextFraction, in: 0.35...0.8, step: 0.05) { Text("Resize Context panel") }
            }
    }
}

/// The sidebar over the whole screen (iPhone): a full-screen cover on iOS, a sheet elsewhere.
struct SidebarCover: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { sidebar }
        #else
        content.sheet(isPresented: $isPresented) { sidebar.frame(minWidth: 320, minHeight: 520) }
        #endif
    }

    private var sidebar: some View {
        SidebarView(onPick: { isPresented = false }, onClose: { isPresented = false }).environment(env)
    }
}

/// iPhone Duo's second screen: the tabs sidebar or the Context panel, switched by a segmented control.
struct DuoSecondaryPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    enum Pane: String, CaseIterable, Identifiable { case tabs = "Tabs", context = "Context"; var id: String { rawValue } }
    @State private var pane: Pane = .tabs

    var body: some View {
        VStack(spacing: 0) {
            Picker("Second screen", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(pane == .tabs ? KageTokens.sidebarGraphite : Color.clear)
            .environment(\.colorScheme, pane == .tabs ? .dark : colorScheme)
            switch pane {
            case .tabs: SidebarView()
            case .context: ContextPanel()
            }
        }
        .onChange(of: env.isContextVisible) { _, visible in pane = visible ? .context : .tabs }
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
