import Foundation

/// Cloudflare's public `cdn-cgi/trace` answer, the only outside view Kage uses to confirm WARP.
public struct CloudflareTrace: Equatable, Sendable {
    public enum WARP: String, Sendable { case on, plus, off, unknown }
    public var warp: WARP
    public var ip: String?
    public var colo: String?

    public static let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    public init(warp: WARP, ip: String? = nil, colo: String? = nil) { self.warp = warp; self.ip = ip; self.colo = colo }

    public static func parse(_ text: String) -> CloudflareTrace {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return CloudflareTrace(warp: fields["warp"].flatMap(WARP.init(rawValue:)) ?? .unknown, ip: fields["ip"], colo: fields["colo"])
    }

    /// WARP is confirmed only by Cloudflare's own `warp=on` or `warp=plus`.
    public var confirmsWARP: Bool { warp == .on || warp == .plus }

    /// Fetches the trace with no cookies or cache, through whatever route the system uses now.
    public static func fetch(session: URLSession? = nil) async throws -> CloudflareTrace {
        let s = session ?? {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil
            cfg.urlCache = nil
            cfg.timeoutIntervalForRequest = 10
            return URLSession(configuration: cfg)
        }()
        let (data, response) = try await s.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return parse(text)
    }
}

/// The tunnel's connection state as the system reports it (mirrors `NEVPNStatus` without importing it).
public enum TunnelConnection: Equatable, Sendable {
    case notInstalled, invalid, disconnected, connecting, connected, reasserting, disconnecting
}
