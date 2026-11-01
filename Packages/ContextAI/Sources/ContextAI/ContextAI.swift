import Foundation
import KageModels

public struct ExtractedContent: Sendable, Equatable {
    public var sourceURL: URL
    public var title: String
    public var text: String
    public init(sourceURL: URL, title: String, text: String) {
        self.sourceURL = sourceURL; self.title = title; self.text = text
    }
}

public protocol ContentExtracting: Sendable {
    /// Runs in a Kage-owned `WKContentWorld`, bounded to `maxBytes` (spec 8.2, 13.5).
    func extract(tabID: UUID, maxBytes: Int) async throws -> ExtractedContent
}

/// Local redaction before anything leaves the device (spec 13.5 step 4).
public struct Redactor: Sendable {
    public var maxBytes: Int
    public init(maxBytes: Int = 32 * 1024) { self.maxBytes = maxBytes }

    public func redact(_ content: ExtractedContent) -> ExtractedContent {
        var text = content.text
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,   // email addresses
            #"\b(?:\d[ -]?){13,19}\b"#,                   // card-like digit runs
        ]
        for p in patterns {
            text = text.replacingOccurrences(of: p, with: "[redacted]", options: [.regularExpression, .caseInsensitive])
        }
        if text.utf8.count > maxBytes {
            // Cut on a character boundary so the result never exceeds maxBytes.
            var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
            while end.samePosition(in: text) == nil { end = text.utf8.index(before: end) }
            text = String(text[..<end])
        }
        var out = content
        out.text = text
        // Query strings often carry tokens; send only scheme, host and path.
        var comps = URLComponents(url: content.sourceURL, resolvingAgainstBaseURL: false)
        comps?.query = nil; comps?.fragment = nil; comps?.user = nil; comps?.password = nil
        out.sourceURL = comps?.url ?? content.sourceURL
        return out
    }
}

public enum SummaryStyle: String, Sendable { case quick, detailed, technical }

public struct SummaryRequest: Sendable {
    public var content: ExtractedContent
    public var style: SummaryStyle
    public var modelID: String
    public init(content: ExtractedContent, style: SummaryStyle, modelID: String) {
        self.content = content; self.style = style; self.modelID = modelID
    }
}

public struct SummaryResult: Sendable {
    /// Rendered as untrusted plain text, never as HTML or script (spec 13.5 step 7).
    public var text: String
    public var proposedActions: [ProposedAction]
}

/// The only things AI output can suggest. Each needs user confirmation; none run automatically (spec 8.6, AT09).
public enum ProposedAction: Sendable, Equatable {
    case openInBackgroundTab(URL)
    case saveNote(String)
    case compareTabs([UUID])
}

public enum AIError: Error, Sendable, Equatable {
    case notConfigured, invalidToken, quotaExceeded, rateLimited(retryAfter: TimeInterval?)
    case unsupportedModel, malformedResponse, offline, cancelled, http(Int)
}

public protocol AIInferenceClient: Sendable {
    func summarise(_ request: SummaryRequest) async throws -> SummaryResult
    func ask(_ question: String, about content: ExtractedContent, modelID: String) -> AsyncThrowingStream<String, Error>
}

/// Builds Workers AI REST requests (spec 8.2). Endpoint: POST /client/v4/accounts/{id}/ai/run/{model}.
/// Paths and the response shape are to be confirmed against Cloudflare docs in M0 (K-02).
public enum CloudflareRequestBuilder {
    public static func runRequest(accountID: String, token: String, modelID: String,
                                  messages: [(role: String, content: String)], stream: Bool) throws -> URLRequest {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let acct = accountID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(acct)/ai/run/\(modelID)")
        else { throw AIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public static func mapStatus(_ code: Int) -> AIError? {
        switch code {
        case 200..<300: return nil
        case 401, 403: return .invalidToken
        case 429: return .rateLimited(retryAfter: nil)
        case 404: return .unsupportedModel
        default: return .http(code)
        }
    }
}
