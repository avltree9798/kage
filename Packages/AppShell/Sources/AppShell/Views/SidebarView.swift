#if canImport(WebKit)
import SwiftUI
import KageModels
import BrowserCore
import PrivacyKit
import DesignSystem

/// The tab sidebar: profile switcher, pinned sites, folders (tab groups) and open tabs, with the
/// app destinations in a floating toolbar. A column beside the page on wide windows, a full screen
/// on iPhone, and the second screen's "Tabs" view on iPhone Duo.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    /// Called after a tab is chosen, so a full-screen sidebar can close.
    var onPick: () -> Void = {}
    /// Shows the address field at the top (the sidebar column on Mac and iPad).
    var showsAddress = false
    /// When set, a "Page" button returns to the page (the full-screen sidebar on iPhone).
    var onClose: (() -> Void)?
    @State private var collapsedGroups: Set<UUID> = []
    @State private var showOverview = false
    @State private var showNewGroup = false
    @State private var newGroupName = ""

    var store: BrowserTabStore { env.currentStore }
    var tint: Color { KageTokens.profileTint(env.currentKind.rawValue) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(tint).frame(height: 3).accessibilityHidden(true)
            if let onClose {
                HStack {
                    Button(action: onClose) { Label("Page", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.body.weight(.semibold)).foregroundStyle(tint)
                    Spacer()
                    Text("\(store.tabs.count) tabs").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if showsAddress {
                OmniboxField(showsProfileChip: false, onSidebar: true)
                    .padding(.horizontal, 12).padding(.top, 10)
                    .zIndex(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ProfileSwitcher()
                    if !pinnedTabs.isEmpty { pinnedGrid }
                    header
                    ForEach(store.groups) { folder($0) }
                    if !store.groups.isEmpty { Divider().overlay(.white.opacity(0.15)) }
                    newTabRow
                    ForEach(looseTabs, id: \.id) { row($0) }
                }
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 80)
            }
            .overlay(alignment: .bottomTrailing) { toolbar.padding(12) }
        }
        .background { KageTokens.sidebarGraphite.ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showOverview) { TabOverviewView().environment(env) }
        .alert("New Folder", isPresented: $showNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                store.createGroup(name: newGroupName.isEmpty ? "Folder" : newGroupName, colour: "indigo")
                newGroupName = ""
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs sidebar")
    }

    // MARK: Sections

    private var pinnedTabs: [TabController] { store.tabs.filter { store.pinned.contains($0.id) } }
    private var looseTabs: [TabController] {
        store.tabs.filter { !store.pinned.contains($0.id) && store.groupMembership[$0.id] == nil }
    }

    private var pinnedGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(pinnedTabs, id: \.id) { tab in
                Button { pick(tab) } label: {
                    SiteMonogram(host: tab.host, tint: tint, size: 26)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.white.opacity(tab.id == store.activeTabID ? 0.22 : 0.09),
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pinned: \(displayTitle(tab))")
                .accessibilityAddTraits(tab.id == store.activeTabID ? .isSelected : [])
                .contextMenu {
                    Button("Unpin", systemImage: "pin.slash") { store.togglePin(tab.id) }
                    Button("Close", systemImage: "xmark", role: .destructive) { store.close(tab.id) }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: ProfileSwitcher.symbol(env.currentKind)).foregroundStyle(tint)
            Text(env.currentProfile.name).font(.headline)
            Spacer()
            Menu {
                Button("New Folder", systemImage: "folder.badge.plus") { showNewGroup = true }
                Button("Tab Overview", systemImage: "square.grid.2x2") { showOverview = true }
                Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { store.reopenLastClosed() }
                    .disabled(store.recentlyClosed.isEmpty)
                Divider()
                Button("Close Other Tabs", systemImage: "xmark.square") { store.closeOtherTabs() }
                if env.lock.isEnabled {
                    Button("Lock Kage", systemImage: "lock") { env.lock.lock(trigger: .manual) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("\(env.currentProfile.name) options")
        }
    }

    private func folder(_ g: TabGroup) -> some View {
        let members = store.tabs.filter { store.groupMembership[$0.id] == g.id }
        let open = !collapsedGroups.contains(g.id)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if open { collapsedGroups.insert(g.id) } else { collapsedGroups.remove(g.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "folder.fill" : "folder").foregroundStyle(KageTokens.accents[g.colour] ?? tint)
                    Text(g.name).lineLimit(1)
                    Spacer()
                    Text("\(members.count)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Folder \(g.name), \(members.count) tabs")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .contextMenu {
                Button("Delete Folder", systemImage: "trash", role: .destructive) { store.deleteGroup(g.id, closingTabs: false) }
            }
            if open { ForEach(members, id: \.id) { row($0).padding(.leading, 18) } }
        }
    }

    private var newTabRow: some View {
        Button { store.open(env.homeURL); onPick() } label: {
            Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ tab: TabController) -> some View {
        let active = tab.id == store.activeTabID
        return HStack(spacing: 10) {
            Button { pick(tab) } label: {
                HStack(spacing: 10) {
                    SiteMonogram(host: tab.host, tint: tint, size: 18)
                    Text(displayTitle(tab)).lineLimit(1)
                        .foregroundStyle(tab.isResident || active ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayTitle(tab))\(tab.isResident ? "" : ", suspended")")
            .accessibilityAddTraits(active ? .isSelected : [])
            if active {
                Button { store.close(tab.id) } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(displayTitle(tab))")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(active ? AnyShapeStyle(.white.opacity(0.16)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Pin", systemImage: "pin") { store.togglePin(tab.id) }
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(tab.id) }
            if !store.groups.isEmpty {
                Menu("Move to Folder") {
                    Button("No Folder") { store.move(tab.id, toGroup: nil) }
                    ForEach(store.groups) { g in Button(g.name) { store.move(tab.id, toGroup: g.id) } }
                }
            }
            Button("Add to Research", systemImage: "tray.and.arrow.down") { env.context.addToResearch(tab.id) }
            Button("Close", systemImage: "xmark", role: .destructive) { store.close(tab.id) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            Button { env.destination = .library } label: { Label("Library", systemImage: "books.vertical") }
            Button { env.destination = .privacy } label: { Label("Privacy", systemImage: "hand.raised") }
            Button { env.destination = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func pick(_ tab: TabController) {
        Task { await store.activate(tab.id) }
        onPick()
    }

    private func displayTitle(_ tab: TabController) -> String {
        tab.title.isEmpty ? (tab.url?.kageHost ?? "New Tab") : tab.title
    }
}

/// Standard, Ghost, Vault and Private as one switcher, each with its own symbol and name.
struct ProfileSwitcher: View {
    @Environment(AppEnvironment.self) private var env
    static let kinds: [PrivacyProfile.Kind] = [.standard, .ghost, .vault, .private]

    static func symbol(_ kind: PrivacyProfile.Kind) -> String {
        switch kind {
        case .standard: "globe"
        case .ghost: "moon.stars"
        case .vault: "lock.shield"
        case .private: "eye.slash"
        }
    }

    static func name(_ kind: PrivacyProfile.Kind) -> String {
        switch kind {
        case .standard: "Standard"
        case .ghost: "Ghost"
        case .vault: "Vault"
        case .private: "Private"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.kinds, id: \.self) { kind in
                let selected = kind == env.currentKind
                Button { Task { await env.switchProfile(to: kind) } } label: {
                    Image(systemName: Self.symbol(kind))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected ? KageTokens.profileTint(kind.rawValue) : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(selected ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.name(kind))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(Self.name(kind))
            }
        }
        .padding(4)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

/// Kage has no favicons (fetching them leaks visits), so sites get a monogram instead.
struct SiteMonogram: View {
    let host: String
    let tint: Color
    let size: CGFloat
    var body: some View {
        let letter = host.replacingOccurrences(of: "www.", with: "").first.map { String($0).uppercased() }
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(tint.opacity(0.35))
            if let letter {
                Text(letter).font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.55))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#endif
