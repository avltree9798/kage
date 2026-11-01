import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A WireGuard tunnel in wg-quick format (spec 11, ADR-008 rev. 2). Kage parses and validates it itself
/// so a bad import fails in the app with a clear message instead of silently in the extension.
/// Private and preshared keys are secrets: this type never prints them (`description` redacts).
public struct WireGuardConfig: Equatable, Sendable, CustomStringConvertible {
    public struct Interface: Equatable, Sendable {
        public var privateKey: String
        public var addresses: [String]
        public var dns: [String]
        public var mtu: Int?
        public var listenPort: Int?
    }

    public struct Peer: Equatable, Sendable {
        public var publicKey: String
        public var presharedKey: String?
        public var allowedIPs: [String]
        public var endpoint: String?
        public var persistentKeepalive: Int?
    }

    public var interface: Interface
    public var peers: [Peer]

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingInterface
        case noPeers
        case unknownSection(line: Int, name: String)
        case keyOutsideSection(line: Int)
        case malformedLine(line: Int)
        case missingKey(section: String, key: String)
        case invalidKey(field: String)
        case invalidAddress(String)
        case invalidEndpoint(String)
        case invalidNumber(field: String, value: String)
        case duplicateInterface

        public var description: String {
            switch self {
            case .missingInterface: "The file has no [Interface] section."
            case .noPeers: "The file has no [Peer] section."
            case .unknownSection(let line, let name): "Line \(line): unknown section [\(name)]."
            case .keyOutsideSection(let line): "Line \(line): setting outside a section."
            case .malformedLine(let line): "Line \(line) isn't in \"Key = Value\" form."
            case .missingKey(let section, let key): "[\(section)] is missing \(key)."
            case .invalidKey(let field): "\(field) isn't a valid WireGuard key."
            case .invalidAddress(let value): "\"\(value)\" isn't a valid IP address or range."
            case .invalidEndpoint(let value): "\"\(value)\" isn't a valid endpoint (host:port)."
            case .invalidNumber(let field, let value): "\(field) \"\(value)\" isn't a valid number."
            case .duplicateInterface: "The file has more than one [Interface] section."
            }
        }
    }

    public init(interface: Interface, peers: [Peer]) {
        self.interface = interface; self.peers = peers
    }

    public var description: String {
        "WireGuardConfig(addresses: \(interface.addresses), peers: \(peers.count), endpoints: \(peers.compactMap(\.endpoint)))"
    }

    /// True when every IPv4 (and, if the interface has an IPv6 address, IPv6) destination goes through the tunnel.
    public var routesAllTraffic: Bool {
        let allowed = Set(peers.flatMap(\.allowedIPs))
        return allowed.contains("0.0.0.0/0") && (!interface.addresses.contains { $0.contains(":") } || allowed.contains("::/0"))
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> WireGuardConfig {
        enum Section { case interface, peer }
        var section: Section?
        var interfaceFields: [String: String]?
        var peerFields: [[String: String]] = []

        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            var line = Substring(raw)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let name = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                switch name.lowercased() {
                case "interface":
                    if interfaceFields != nil { throw ParseError.duplicateInterface }
                    interfaceFields = [:]; section = .interface
                case "peer":
                    peerFields.append([:]); section = .peer
                default:
                    throw ParseError.unknownSection(line: lineNumber, name: name)
                }
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { throw ParseError.malformedLine(line: lineNumber) }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ParseError.malformedLine(line: lineNumber) }
            switch section {
            case .interface:
                // Repeated list keys accumulate, as in wg-quick.
                interfaceFields![key] = interfaceFields![key].map { $0 + "," + value } ?? value
            case .peer:
                peerFields[peerFields.count - 1][key] = peerFields[peerFields.count - 1][key].map { $0 + "," + value } ?? value
            case nil:
                throw ParseError.keyOutsideSection(line: lineNumber)
            }
        }

        guard let i = interfaceFields else { throw ParseError.missingInterface }
        guard !peerFields.isEmpty else { throw ParseError.noPeers }

        guard let privateKey = i["privatekey"] else { throw ParseError.missingKey(section: "Interface", key: "PrivateKey") }
        guard isValidKey(privateKey) else { throw ParseError.invalidKey(field: "PrivateKey") }
        let addresses = list(i["address"])
        guard !addresses.isEmpty else { throw ParseError.missingKey(section: "Interface", key: "Address") }
        for a in addresses where !isValidAddressRange(a) { throw ParseError.invalidAddress(a) }
        let dns = list(i["dns"])
        let interface = Interface(privateKey: privateKey, addresses: addresses, dns: dns,
                                  mtu: try number(i["mtu"], field: "MTU", range: 576...65535),
                                  listenPort: try number(i["listenport"], field: "ListenPort", range: 0...65535))

        let peers = try peerFields.map { p -> Peer in
            guard let pub = p["publickey"] else { throw ParseError.missingKey(section: "Peer", key: "PublicKey") }
            guard isValidKey(pub) else { throw ParseError.invalidKey(field: "PublicKey") }
            if let psk = p["presharedkey"], !isValidKey(psk) { throw ParseError.invalidKey(field: "PresharedKey") }
            let allowed = list(p["allowedips"])
            for a in allowed where !isValidAddressRange(a) { throw ParseError.invalidAddress(a) }
            if let e = p["endpoint"], parseEndpoint(e) == nil { throw ParseError.invalidEndpoint(e) }
            return Peer(publicKey: pub, presharedKey: p["presharedkey"], allowedIPs: allowed, endpoint: p["endpoint"],
                        persistentKeepalive: try number(p["persistentkeepalive"], field: "PersistentKeepalive", range: 0...65535))
        }
        return WireGuardConfig(interface: interface, peers: peers)
    }

    /// wg-quick text, the form stored in the Keychain and read by the tunnel extension.
    public var wgQuickText: String {
        var lines = ["[Interface]", "PrivateKey = \(interface.privateKey)", "Address = \(interface.addresses.joined(separator: ", "))"]
        if !interface.dns.isEmpty { lines.append("DNS = \(interface.dns.joined(separator: ", "))") }
        if let mtu = interface.mtu { lines.append("MTU = \(mtu)") }
        if let port = interface.listenPort { lines.append("ListenPort = \(port)") }
        for p in peers {
            lines += ["", "[Peer]", "PublicKey = \(p.publicKey)"]
            if let psk = p.presharedKey { lines.append("PresharedKey = \(psk)") }
            if !p.allowedIPs.isEmpty { lines.append("AllowedIPs = \(p.allowedIPs.joined(separator: ", "))") }
            if let e = p.endpoint { lines.append("Endpoint = \(e)") }
            if let k = p.persistentKeepalive { lines.append("PersistentKeepalive = \(k)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Validation helpers

    static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func number(_ value: String?, field: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value else { return nil }
        guard let n = Int(value), range.contains(n) else { throw ParseError.invalidNumber(field: field, value: value) }
        return n
    }

    /// A WireGuard key is 32 bytes in standard base64 (44 characters with one `=`).
    public static func isValidKey(_ key: String) -> Bool {
        key.count == 44 && Data(base64Encoded: key)?.count == 32
    }

    public static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    public static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    /// `10.0.0.2`, `10.0.0.0/24`, `fd00::2/128`.
    public static func isValidAddressRange(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let ip = String(parts[0])
        let maxPrefix: Int
        if isIPv4(ip) { maxPrefix = 32 } else if isIPv6(ip) { maxPrefix = 128 } else { return false }
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...maxPrefix).contains(p) else { return false }
        }
        return true
    }

    /// `host:port`, `1.2.3.4:51820` or `[2606:4700::1]:2408`.
    public static func parseEndpoint(_ s: String) -> (host: String, port: Int)? {
        let host: String, portText: Substring
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]"), s[s.index(after: close)...].hasPrefix(":") else { return nil }
            host = String(s[s.index(after: s.startIndex)..<close])
            guard isIPv6(host) else { return nil }
            portText = s[s.index(close, offsetBy: 2)...]
        } else {
            guard let colon = s.lastIndex(of: ":"), s.firstIndex(of: ":") == colon else { return nil }
            host = String(s[..<colon])
            portText = s[s.index(after: colon)...]
            let hostChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
            guard !host.isEmpty, host.unicodeScalars.allSatisfy(hostChars.contains) else { return nil }
        }
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }
}
