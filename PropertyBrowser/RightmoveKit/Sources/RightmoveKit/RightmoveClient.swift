import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configuration for `RightmoveClient`. Defaults mimic Safari on macOS so plain
/// requests look like a real browser. Optionally supply a `cookie` copied from a
/// logged-in/whitelisted browser session, which is the most reliable way past
/// Cloudflare if cookieless requests get challenged.
public struct RightmoveClientConfig: Sendable {
    public var userAgent: String
    public var acceptLanguage: String
    /// Raw `Cookie:` header value, e.g. copied from your browser's dev tools.
    public var cookie: String?
    /// Minimum gap between requests, to stay polite and reduce block risk.
    public var minRequestInterval: TimeInterval
    public var timeout: TimeInterval

    public init(
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
        acceptLanguage: String = "en-GB,en;q=0.9",
        cookie: String? = nil,
        minRequestInterval: TimeInterval = 2.0,
        timeout: TimeInterval = 30.0
    ) {
        self.userAgent = userAgent
        self.acceptLanguage = acceptLanguage
        self.cookie = cookie
        self.minRequestInterval = minRequestInterval
        self.timeout = timeout
    }
}

/// The result of fetching a Rightmove page.
public enum FetchOutcome: Sendable {
    /// Got real HTML containing the expected embedded JSON.
    case ok(html: String, statusCode: Int, byteCount: Int)
    /// A Cloudflare / bot-wall page (or an HTTP status that implies one).
    case challenged(statusCode: Int, reason: String, byteCount: Int)
    /// A non-success HTTP status that isn't obviously a challenge.
    case httpError(statusCode: Int, byteCount: Int)
}

public enum RightmoveClientError: Error, CustomStringConvertible {
    case challenged(reason: String, statusCode: Int)
    case httpError(statusCode: Int)
    case notHTTP
    case badURL

    public var description: String {
        switch self {
        case .challenged(let r, let s): return "Blocked by a challenge page (HTTP \(s)): \(r)"
        case .httpError(let s): return "HTTP error \(s)"
        case .notHTTP: return "Response was not an HTTP response"
        case .badURL: return "Could not build a valid URL"
        }
    }
}

/// Detects Cloudflare / bot-wall responses so we can tell a real page from a
/// challenge instead of trying to parse garbage.
public enum ChallengeDetector {
    private static let bodyMarkers = [
        "Just a moment...",
        "cf-browser-verification",
        "challenge-platform",
        "Attention Required! | Cloudflare",
        "Enable JavaScript and cookies to continue",
        "_cf_chl_opt",
        "/cdn-cgi/challenge-platform",
        "Please verify you are a human",
    ]

    /// Returns a human-readable reason if `html`/`statusCode` looks like a
    /// challenge, otherwise nil.
    public static func reason(html: String, statusCode: Int) -> String? {
        for marker in bodyMarkers where html.contains(marker) {
            return "matched marker “\(marker)”"
        }
        if statusCode == 403 { return "HTTP 403 (Forbidden) — typical bot block" }
        if statusCode == 503 { return "HTTP 503 — typical Cloudflare interstitial" }
        if statusCode == 429 { return "HTTP 429 — rate limited" }
        // A "200" with neither embedded payload and a tiny body is suspicious.
        let hasPayload = html.contains("__NEXT_DATA__") || html.contains("window.__PAGE_MODEL")
        if !hasPayload && html.count < 30_000 {
            return "no embedded JSON and body is only \(html.count) bytes"
        }
        return nil
    }
}

/// Fetches Rightmove pages and turns them into typed models. An actor so the
/// politeness throttle is serialised across concurrent callers.
public actor RightmoveClient {
    private let config: RightmoveClientConfig
    private let session: URLSession
    private var lastRequest: Date?

    public init(config: RightmoveClientConfig = .init()) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = config.timeout
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: c)
    }

    // MARK: Low-level fetch

    /// Fetches a URL and classifies the response without throwing on a challenge,
    /// so callers (like `netcheck`) can report the outcome.
    public func fetch(_ url: URL) async throws -> FetchOutcome {
        try await throttle()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(config.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("https://www.rightmove.co.uk/", forHTTPHeaderField: "Referer")
        if let cookie = config.cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RightmoveClientError.notHTTP }

        let html = String(decoding: data, as: UTF8.self)
        let byteCount = data.count
        let status = http.statusCode

        if let reason = ChallengeDetector.reason(html: html, statusCode: status) {
            return .challenged(statusCode: status, reason: reason, byteCount: byteCount)
        }
        if !(200...299).contains(status) {
            return .httpError(statusCode: status, byteCount: byteCount)
        }
        return .ok(html: html, statusCode: status, byteCount: byteCount)
    }

    /// Fetches a URL, returning HTML or throwing a `RightmoveClientError`.
    public func fetchHTML(_ url: URL) async throws -> String {
        switch try await fetch(url) {
        case .ok(let html, _, _): return html
        case .challenged(let status, let reason, _): throw RightmoveClientError.challenged(reason: reason, statusCode: status)
        case .httpError(let status, _): throw RightmoveClientError.httpError(statusCode: status)
        }
    }

    // MARK: High-level

    /// Fetches and parses one page of a saved search (defaults to the first page).
    public func fetchSearchResults(_ search: RightmoveSearchURL, index: Int = 0) async throws -> SearchResultsPage {
        guard let url = search.pageURL(index: index) else { throw RightmoveClientError.badURL }
        let html = try await fetchHTML(url)
        return try RightmoveParser.parseSearchResults(html: html)
    }

    /// Looks up locations matching `query` via Rightmove's typeahead endpoint,
    /// returning the candidate places (each with its `locationIdentifier`).
    /// Returns an empty array for a blank/unusable query. Throws
    /// `RightmoveClientError` on a challenge or HTTP error so callers can
    /// distinguish "no matches" from "lookup failed".
    public func fetchLocationSuggestions(query: String) async throws -> [LocationSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = RightmoveTypeAhead.url(for: trimmed) else { return [] }

        try await throttle()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        // Accept: application/json is required — the endpoint defaults to XML
        // for a browser-style Accept. Referer is required or it 404s.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.rightmove.co.uk/", forHTTPHeaderField: "Referer")
        if let cookie = config.cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RightmoveClientError.notHTTP }
        let status = http.statusCode
        let body = String(decoding: data, as: UTF8.self)

        // Challenge / bot-wall detection — but skip the tiny-body heuristic the
        // page detector uses, since a JSON typeahead reply is legitimately small.
        if status == 403 { throw RightmoveClientError.challenged(reason: "HTTP 403 (Forbidden)", statusCode: status) }
        if status == 503 { throw RightmoveClientError.challenged(reason: "HTTP 503 — Cloudflare interstitial", statusCode: status) }
        if status == 429 { throw RightmoveClientError.challenged(reason: "HTTP 429 — rate limited", statusCode: status) }
        if let marker = ["Just a moment...", "challenge-platform", "cf-browser-verification"].first(where: { body.contains($0) }) {
            throw RightmoveClientError.challenged(reason: "matched marker “\(marker)”", statusCode: status)
        }
        guard (200...299).contains(status) else { throw RightmoveClientError.httpError(statusCode: status) }

        let decoded = try JSONDecoder().decode(TypeAheadResponse.self, from: data)
        // Drop any match we couldn't assemble an identifier for.
        return decoded.matches.filter { !$0.locationIdentifier.isEmpty }
    }

    /// Fetches and parses a property's detail page by id.
    public func fetchPropertyDetail(id: Int) async throws -> PropertyDetail {
        guard let url = URL(string: "https://www.rightmove.co.uk/properties/\(id)") else {
            throw RightmoveClientError.badURL
        }
        let html = try await fetchHTML(url)
        return try RightmoveParser.parsePropertyDetail(html: html)
    }

    // MARK: Politeness

    private func throttle() async throws {
        if let last = lastRequest {
            let elapsed = Date().timeIntervalSince(last)
            let wait = config.minRequestInterval - elapsed
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequest = Date()
    }
}
