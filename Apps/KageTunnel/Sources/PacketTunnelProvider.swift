import Foundation
import NetworkExtension
import NetworkTunnel
import WireGuardKit
import os

/// Kage's WireGuard packet tunnel (ADR-008 rev. 2). It reads the wg-quick text from the shared Keychain
/// item named by the profile's `passwordReference` and runs it with WireGuardKit. It logs no keys,
/// addresses or traffic.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "dev.kage.tunnel", category: "tunnel")

    private lazy var adapter: WireGuardAdapter = WireGuardAdapter(with: self) { [log] level, _ in
        // WireGuard's own messages can include endpoint addresses; record only that something was logged.
        if level == .error { log.error("wireguard reported an error") }
    }

    enum TunnelError: Error { case noConfiguration, invalidConfiguration }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let ref = proto.passwordReference,
              let text = TunnelKeychain.load(persistentReference: ref) else {
            completionHandler(TunnelError.noConfiguration)
            return
        }
        guard let parsed = try? WireGuardConfig.parse(text),
              let configuration = WireGuardKitBridge.tunnelConfiguration(parsed, name: proto.serverAddress) else {
            completionHandler(TunnelError.invalidConfiguration)
            return
        }
        adapter.start(tunnelConfiguration: configuration) { [log] error in
            if let error { log.error("start failed: \(String(describing: error), privacy: .public)") }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }
}

/// Converts Kage's validated config into WireGuardKit's types.
enum WireGuardKitBridge {
    static func tunnelConfiguration(_ c: WireGuardConfig, name: String?) -> TunnelConfiguration? {
        guard let key = PrivateKey(base64Key: c.interface.privateKey) else { return nil }
        var interface = InterfaceConfiguration(privateKey: key)
        interface.addresses = c.interface.addresses.compactMap { IPAddressRange(from: $0) }
        interface.dns = c.interface.dns.compactMap { DNSServer(from: $0) }
        interface.mtu = c.interface.mtu.map(UInt16.init)
        interface.listenPort = c.interface.listenPort.map(UInt16.init)
        var peers: [PeerConfiguration] = []
        for p in c.peers {
            guard let pub = PublicKey(base64Key: p.publicKey) else { return nil }
            var peer = PeerConfiguration(publicKey: pub)
            if let psk = p.presharedKey {
                guard let k = PreSharedKey(base64Key: psk) else { return nil }
                peer.preSharedKey = k
            }
            peer.allowedIPs = p.allowedIPs.compactMap { IPAddressRange(from: $0) }
            if let e = p.endpoint {
                guard let endpoint = Endpoint(from: e) else { return nil }
                peer.endpoint = endpoint
            }
            peer.persistentKeepAlive = p.persistentKeepalive.map(UInt16.init)
            peers.append(peer)
        }
        return TunnelConfiguration(name: name, interface: interface, peers: peers)
    }
}
