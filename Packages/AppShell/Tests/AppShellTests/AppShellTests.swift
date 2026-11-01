import Foundation
import Testing
import KageModels
import NetworkTunnel
@testable import AppShell

@Suite struct NetworkProtectionTests {
    // AT16: with status unknown, the UI never claims verified protection.
    @Test func unknownNeverClaimsProtection() {
        for s in [NetworkProtectionState.notConfigured, .statusUnknown(detail: "warp=on"), .connecting, .disconnected, .restricted("x")] {
            #expect(!s.claimsProtection)
            #expect(s.symbol == "shield.slash")
        }
        #expect(NetworkProtectionState.verifiedConnected.claimsProtection)
    }

    @MainActor @Test func monitorStartsUnconfiguredAndStaysUnknown() {
        let m = NetworkProtectionMonitor()
        #expect(m.state == .notConfigured)
        m.userSaysWARPInstalled = true
        #expect(m.state == .statusUnknown(detail: nil))
        #expect(!m.state.claimsProtection)
    }

    // AT16 with Kage's tunnel: protection needs the tunnel up AND Cloudflare's warp=on.
    @Test func resolveRules() {
        let on = CloudflareTrace(warp: .on, ip: "104.28.0.1")
        let off = CloudflareTrace(warp: .off, ip: "203.0.113.9")
        #expect(NetworkProtectionState.resolve(tunnel: .connected, trace: on, userSaysWARPInstalled: false) == .verifiedConnected)
        #expect(NetworkProtectionState.resolve(tunnel: .connected, trace: off, userSaysWARPInstalled: false) == .tunnelWithoutWARP(exitIP: "203.0.113.9"))
        #expect(!NetworkProtectionState.resolve(tunnel: .connected, trace: nil, userSaysWARPInstalled: true).claimsProtection)
        #expect(NetworkProtectionState.resolve(tunnel: .disconnected, trace: on, userSaysWARPInstalled: false) == .disconnected)
        #expect(NetworkProtectionState.resolve(tunnel: .connecting, trace: on, userSaysWARPInstalled: false) == .connecting)
        #expect(NetworkProtectionState.resolve(tunnel: .notInstalled, trace: on, userSaysWARPInstalled: false) == .notConfigured)
        // Without Kage's tunnel, even warp=on from the WARP app is only an observation.
        #expect(NetworkProtectionState.resolve(tunnel: nil, trace: on, userSaysWARPInstalled: true) == .statusUnknown(detail: nil))
    }

    @MainActor @Test func monitorVerifiesWithCloudflareWhenTunnelConnects() async {
        let fake = FakeTunnel()
        let m = NetworkProtectionMonitor(manager: fake, traceFetcher: { CloudflareTrace(warp: .on, ip: "104.28.0.1") })
        await m.start()
        #expect(m.state == .notConfigured)
        let ok = await m.importConfig(Self.config)
        #expect(ok)
        #expect(m.state == .disconnected)
        await m.apply(.connected)
        #expect(m.state == .verifiedConnected)
        await m.apply(.disconnected)
        #expect(m.state == .disconnected)
        let bad = await m.importConfig("[Interface]\nPrivateKey = nope")
        #expect(!bad)
        #expect(m.lastError != nil)
    }

    @MainActor @Test func tunnelUpButNotWARPIsNotProtected() async {
        let m = NetworkProtectionMonitor(manager: FakeTunnel(), traceFetcher: { CloudflareTrace(warp: .off, ip: "198.51.100.4") })
        await m.apply(.connected)
        #expect(m.state == .tunnelWithoutWARP(exitIP: "198.51.100.4"))
        #expect(!m.state.claimsProtection)
    }

    static let config = """
    [Interface]
    PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
    Address = 172.16.0.2/32
    [Peer]
    PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
    AllowedIPs = 0.0.0.0/0
    Endpoint = 162.159.192.1:2408
    """
}

final class FakeTunnel: TunnelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var status: TunnelConnection = .notInstalled
    func connection() async -> TunnelConnection { lock.withLock { status } }
    func install(_ config: WireGuardConfig, name: String) async throws { lock.withLock { status = .disconnected } }
    func remove() async throws { lock.withLock { status = .notInstalled } }
    func start() async throws { lock.withLock { status = .connected } }
    func stop() async { lock.withLock { status = .disconnected } }
    func statusUpdates() -> AsyncStream<TunnelConnection> { AsyncStream { _ in } }
}

@Suite struct BookmarkHTMLTests {
    @Test func roundTrip() {
        let b = [Bookmark(url: URL(string: "https://a.test/?x=1&y=2")!, title: "A & B <c>", tags: ["t"])]
        let parsed = BookmarkHTML.parse(BookmarkHTML.render(b))
        #expect(parsed.count == 1)
        #expect(parsed[0].url == b[0].url)
        #expect(parsed[0].title == "A & B <c>")
    }

    @Test func ignoresNonWebLinks() {
        let html = #"<DT><A HREF="javascript:alert(1)">x</A><DT><A HREF="https://ok.test">ok</A>"#
        #expect(BookmarkHTML.parse(html).map(\.title) == ["ok"])
    }
}

@MainActor @Suite struct SettingsTests {
    @Test func defaultsArePrivate() {
        let d = UserDefaults(suiteName: "kage.tests.\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        #expect(s.smartPreSummary == false)          // spec 8.4: default off
        #expect(s.searchSuggestions == false)        // spec 6.1: optional
        #expect(s.lockMode == .none)
        #expect(s.retentionOverride == nil)
        s.retentionMinutes = 0
        #expect(s.retentionOverride == .onTabClose)
        #expect(AppSettings(defaults: d).retentionMinutes == 0)
    }
}
