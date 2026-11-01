import Foundation
import Testing
@testable import NetworkTunnel

// Throwaway keys generated for tests only; they protect nothing.
private let priv = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
private let pub = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="
private let psk = "FpCyhws9cxwWoV4xELtfJvjJN+zQVRPISllRWgeopVE="

private let warpLike = """
[Interface]
PrivateKey = \(priv)
Address = 172.16.0.2/32, 2606:4700:110:8a36::1/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

# Cloudflare edge
[Peer]
PublicKey = \(pub)
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = engage.cloudflareclient.com:2408
"""

@Suite struct WireGuardConfigTests {
    @Test func parsesWgQuick() throws {
        let c = try WireGuardConfig.parse(warpLike)
        #expect(c.interface.addresses == ["172.16.0.2/32", "2606:4700:110:8a36::1/128"])
        #expect(c.interface.dns == ["1.1.1.1", "1.0.0.1"])
        #expect(c.interface.mtu == 1280)
        #expect(c.peers.count == 1)
        #expect(c.peers[0].allowedIPs == ["0.0.0.0/0", "::/0"])
        #expect(c.peers[0].endpoint == "engage.cloudflareclient.com:2408")
        #expect(c.routesAllTraffic)
    }

    @Test func roundTrips() throws {
        var c = try WireGuardConfig.parse(warpLike)
        c.peers[0].presharedKey = psk
        c.peers[0].persistentKeepalive = 25
        #expect(try WireGuardConfig.parse(c.wgQuickText) == c)
    }

    @Test func descriptionNeverContainsKeys() throws {
        var c = try WireGuardConfig.parse(warpLike)
        c.peers[0].presharedKey = psk
        let text = "\(c)" + String(describing: c)
        #expect(!text.contains(priv))
        #expect(!text.contains(psk))
    }

    @Test func rejectsBadInput() {
        #expect(throws: WireGuardConfig.ParseError.missingInterface) { try WireGuardConfig.parse("[Peer]\nPublicKey = \(pub)") }
        #expect(throws: WireGuardConfig.ParseError.noPeers) { try WireGuardConfig.parse("[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2/32") }
        #expect(throws: WireGuardConfig.ParseError.invalidKey(field: "PrivateKey")) {
            try WireGuardConfig.parse(warpLike.replacingOccurrences(of: priv, with: "short"))
        }
        #expect(throws: WireGuardConfig.ParseError.invalidAddress("10.0.0.300/32")) {
            try WireGuardConfig.parse(warpLike.replacingOccurrences(of: "172.16.0.2/32", with: "10.0.0.300/32"))
        }
        #expect(throws: WireGuardConfig.ParseError.invalidEndpoint("example.com")) {
            try WireGuardConfig.parse(warpLike.replacingOccurrences(of: "engage.cloudflareclient.com:2408", with: "example.com"))
        }
        #expect(throws: WireGuardConfig.ParseError.unknownSection(line: 1, name: "Bogus")) { try WireGuardConfig.parse("[Bogus]") }
        #expect(throws: WireGuardConfig.ParseError.keyOutsideSection(line: 1)) { try WireGuardConfig.parse("PrivateKey = x") }
        #expect(throws: WireGuardConfig.ParseError.invalidNumber(field: "MTU", value: "9")) {
            try WireGuardConfig.parse(warpLike.replacingOccurrences(of: "MTU = 1280", with: "MTU = 9"))
        }
    }

    @Test func endpoints() {
        let v4 = WireGuardConfig.parseEndpoint("162.159.192.1:2408")
        #expect(v4?.host == "162.159.192.1" && v4?.port == 2408)
        let v6 = WireGuardConfig.parseEndpoint("[2606:4700:d0::a29f:c001]:2408")
        #expect(v6?.host == "2606:4700:d0::a29f:c001" && v6?.port == 2408)
        #expect(WireGuardConfig.parseEndpoint("host:0") == nil)
        #expect(WireGuardConfig.parseEndpoint("2606:4700::1:2408") == nil)
        #expect(WireGuardConfig.parseEndpoint("bad host:51820") == nil)
    }

    @Test func splitTunnelIsNotFullRoute() throws {
        let c = try WireGuardConfig.parse(warpLike.replacingOccurrences(of: "AllowedIPs = 0.0.0.0/0\nAllowedIPs = ::/0", with: "AllowedIPs = 10.0.0.0/8"))
        #expect(!c.routesAllTraffic)
    }
}

@Suite struct TraceTests {
    @Test func parsesTrace() {
        let t = CloudflareTrace.parse("fl=1\nh=www.cloudflare.com\nip=104.28.1.2\ncolo=NRT\nwarp=on\ngateway=off\n")
        #expect(t == CloudflareTrace(warp: .on, ip: "104.28.1.2", colo: "NRT"))
        #expect(t.confirmsWARP)
        #expect(CloudflareTrace.parse("warp=plus").confirmsWARP)
        #expect(!CloudflareTrace.parse("warp=off").confirmsWARP)
        #expect(CloudflareTrace.parse("garbage").warp == .unknown)
    }
}
