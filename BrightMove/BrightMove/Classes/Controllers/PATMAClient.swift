import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to PaTMa's browser-extension backend to retrieve a property's
/// historical prices.
///
/// This mirrors what the PaTMa Chrome extension does: it POSTs the rendered
/// Rightmove page (URL + full HTML) to `prospector/be/load_info/`, which parses
/// it server-side and returns a pre-rendered panel. We then extract the price
/// history rows from that HTML.
///
/// A logged-in `sessionid` cookie is optional — the price-history table is
/// returned either way; the cookie only unlocks the gated Rent/Yield figures,
/// which we don't use.
public struct PATMAClient: Sendable {
    public static let endpoint = URL(string: "https://app.patma.co.uk/prospector/be/load_info/")!

    public var userAgent: String
    /// Raw value for a `sessionid` cookie copied from a logged-in PaTMa session.
    public var sessionID: String?
    public var timeout: TimeInterval

    public init(
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
        sessionID: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.userAgent = userAgent
        self.sessionID = sessionID
        self.timeout = timeout
    }

    public enum Failure: Error, CustomStringConvertible {
        case notHTTP
        case httpError(Int)

        public var description: String {
            switch self {
            case .notHTTP: return "PaTMa response was not HTTP"
            case .httpError(let s): return "PaTMa HTTP error \(s)"
            }
        }
    }

    /// Fetch the historical prices for a property, given the same page URL and
    /// raw HTML that the browser would have rendered.
    public func priceHistory(pageURL: URL, html: String) async throws -> [PriceHistoryEntry] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let sessionID, !sessionID.isEmpty {
            request.setValue("sessionid=\(sessionID)", forHTTPHeaderField: "Cookie")
        }

        request.httpBody = Self.formBody([
            "url": pageURL.absoluteString,
            "html": html,
            "agent": userAgent,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw Failure.httpError(http.statusCode) }

        return try PATMAPriceHistoryParser.parse(responseData: data)
    }

    /// `application/x-www-form-urlencoded` body with strict percent-encoding so
    /// the large HTML payload (with its `&`, `=`, `#`, `+`) survives intact.
    static func formBody(_ fields: [String: String]) -> Data {
        // RFC 3986 unreserved set — encode everything else, including "+".
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
