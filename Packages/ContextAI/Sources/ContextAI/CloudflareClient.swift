import Foundation
import SecurityKit

/// One supported model (spec 8.7: model compatibility is versioned and configurable).
public struct AIModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var supportsStreaming: Bool
    /// Rough input budget in characters, derived from the model's context window.
    public var maxInputCharacters: Int
    public init(id: String, name: String, supportsStreaming: Bool, maxInputCharacters: Int) {
        self.id = id; self.name = name; self.supportsStreaming = supportsStreaming; self.maxInputCharacters = maxInputCharacters
    }
}

public struct ModelRegistry: Codable, Sendable {
    public var version: Int
    public var defaultModelID: String
    public var models: [AIModel]

    /// Built-in defaults; `Config/Models.json` mirrors these. Model IDs must be re-checked against
    /// the live Workers AI catalogue before release (spec 24 Q5).
    public static let builtIn = ModelRegistry(version: 1, defaultModelID: "@cf/meta/llama-3.1-8b-instruct", models: [
        AIModel(id: "@cf/meta/llama-3.1-8b-instruct", name: "Llama 3.1 8B (fast)", supportsStreaming: true, maxInputCharacters: 24_000),
        AIModel(id: "@cf/meta/llama-3.3-70b-instruct-fp8-fast", name: "Llama 3.3 70B (detailed)", supportsStreaming: true, maxInputCharacters: 48_000),
    ])

    public static func load(from url: URL) -> ModelRegistry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelRegistry.self, from: data)
    }

    public func model(_ id: String?) -> AIModel {
        models.first { $0.id == id } ?? models.first { $0.id == defaultModelID } ?? models[0]
    }
}

/// Parses Workers AI server-sent events: `data: {"response":"..."}` lines ending with `data: [DONE]`.
public struct SSEParser: Sendable {
    private var buffer = ""
    public init() {}

    public enum Event: Equatable, Sendable { case text(String), done }

    public mutating func feed(_ chunk: String) -> [Event] {
        buffer += chunk
        var events: [Event] = []
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(..<range.upperBound)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { events.append(.done); continue }
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let text = obj["response"] as? String, !text.isEmpty { events.append(.text(text)) }
                // OpenAI-compatible shape, in case the endpoint returns it.
                else if let choices = obj["choices"] as? [[String: Any]],
                        let delta = choices.first?["delta"] as? [String: Any],
                        let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
            }
        }
        return events
    }
}

/// Native Workers AI client (spec 8.2). Credentials come from the Keychain; requests carry no cookies,
/// browser auth headers or page passwords. Browsing never depends on it (AT08, AT13).
public struct CloudflareAIClient: AIInferenceClient {
    let credentials: CredentialStoring
    let session: URLSession

    public init(credentials: CredentialStoring, session: URLSession? = nil) {
        self.credentials = credentials
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            cfg.urlCache = nil
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func complete(_ messages: [ChatMessage], modelID: String, stream: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let cred = try await credentials.load() else { throw AIError.notConfigured }
                    let req = try CloudflareRequestBuilder.runRequest(accountID: cred.accountID, token: cred.apiToken, modelID: modelID,
                                                                      messages: messages.map { ($0.role.rawValue, $0.content) },
                                                                      stream: stream)
                    if stream {
                        let (bytes, response) = try await session.bytes(for: req)
                        try Self.check(response, body: nil)
                        var parser = SSEParser()
                        for try await line in bytes.lines {
                            for event in parser.feed(line + "\n") {
                                switch event {
                                case .text(let t): continuation.yield(t)
                                case .done: continuation.finish(); return
                                }
                            }
                        }
                        continuation.finish()
                    } else {
                        let (data, response) = try await session.data(for: req)
                        try Self.check(response, body: data)
                        continuation.yield(try Self.decodeResponse(data))
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: AIError.cancelled)
                } catch let e as URLError {
                    continuation.finish(throwing: e.code == .cancelled ? AIError.cancelled : AIError.offline)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func validate() async throws -> TokenStatus {
        guard let cred = try await credentials.load() else { return .notConfigured }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let acct = cred.accountID.addingPercentEncoding(withAllowedCharacters: allowed) else { return .invalid }
        // Account-owned tokens verify under the account; user tokens under /user. Try both.
        for path in ["accounts/\(acct)/tokens/verify", "user/tokens/verify"] {
            guard let url = URL(string: "https://api.cloudflare.com/client/v4/\(path)") else { continue }
            var req = URLRequest(url: url)
            req.httpShouldHandleCookies = false
            req.setValue("Bearer \(cred.apiToken)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let status = (obj?["result"] as? [String: Any])?["status"] as? String
                return status == "active" ? .active : .inactive
            } catch let e as URLError {
                _ = e
                throw AIError.offline
            }
        }
        return .invalid
    }

    static func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.malformedResponse }
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw AIError.rateLimited(retryAfter: retry)
        }
        if let err = CloudflareRequestBuilder.mapStatus(http.statusCode) {
            // Cloudflare reports quota exhaustion in the error body.
            if let body, let text = String(data: body, encoding: .utf8)?.lowercased(),
               text.contains("quota") || text.contains("neurons") || text.contains("limit exceeded") {
                throw AIError.quotaExceeded
            }
            throw err
        }
    }

    /// Non-streaming shape: `{"result":{"response":"..."},"success":true}`.
    static func decodeResponse(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.malformedResponse }
        if let result = obj["result"] as? [String: Any], let text = result["response"] as? String { return text }
        if let choices = obj["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any],
           let text = msg["content"] as? String { return text }
        throw AIError.malformedResponse
    }
}

public extension AIError {
    /// Plain message for the Context panel. Browsing is unaffected in every case.
    var userMessage: String {
        switch self {
        case .notConfigured: "Add your Cloudflare account in Settings to use Context AI."
        case .invalidToken: "Cloudflare rejected the API token. It may have been revoked; update it in Settings."
        case .quotaExceeded: "Your Cloudflare Workers AI quota is used up for now."
        case .rateLimited(let after): after.map { "Cloudflare is rate limiting requests. Try again in \(Int($0)) seconds." }
            ?? "Cloudflare is rate limiting requests. Try again shortly."
        case .unsupportedModel: "This model isn't available on your Cloudflare account. Pick another in Settings."
        case .malformedResponse: "Cloudflare sent a response Kage couldn't read."
        case .offline: "Can't reach Cloudflare. Check your connection; browsing still works."
        case .cancelled: "Stopped."
        case .http(let code): "Cloudflare returned an error (\(code))."
        }
    }
}
