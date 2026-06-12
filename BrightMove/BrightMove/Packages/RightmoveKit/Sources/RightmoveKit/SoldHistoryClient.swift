import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One sold transaction from Rightmove's `soldProperty/transactionHistory`
/// endpoint, e.g. `{ "year": "2016", "soldPrice": "£550,000", "percentageChange": "+76%" }`.
/// Year and price arrive as display strings and are parsed to integers here.
public struct SoldTransaction: Decodable, Equatable, Sendable {
    public let year: Int?
    /// Sale price in whole pounds.
    public let price: Int?
    public let percentageChange: String?

    private enum CodingKeys: String, CodingKey { case year, soldPrice, percentageChange }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = (try? c.decode(String.self, forKey: .year)).flatMap { Int($0.filter(\.isNumber)) }
        price = (try? c.decode(String.self, forKey: .soldPrice)).flatMap { Self.parsePrice($0) }
        percentageChange = try? c.decode(String.self, forKey: .percentageChange)
    }

    public init(year: Int?, price: Int?, percentageChange: String? = nil) {
        self.year = year
        self.price = price
        self.percentageChange = percentageChange
    }

    /// "£550,000" → 550000. Returns nil when no digits are present.
    static func parsePrice(_ s: String) -> Int? {
        let digits = s.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }
}

/// Response shape of `soldProperty/transactionHistory`.
public struct SoldPropertyHistory: Decodable, Sendable {
    /// Link to the Rightmove house-prices page for this property, when present.
    public let soldPropertyUrlPath: String?
    public let soldPropertyTransactions: [SoldTransaction]

    /// Most recent sale, if any (the API returns newest first).
    public var lastSold: SoldTransaction? {
        soldPropertyTransactions.max { ($0.year ?? 0) < ($1.year ?? 0) }
    }
}

/// Fetches a property's Land-Registry-sourced sold price history from Rightmove.
///
/// The endpoint is keyed by `deliveryPointId` + `encId`, both of which come from
/// the Rightmove property page model. A logged-in cookie is generally not
/// required for the history table, but the host is bot-protected, so callers may
/// pass a `cookie` (and should reuse a realistic `userAgent`).
public struct SoldHistoryClient: Sendable {
    public static let endpoint = URL(string:
        "https://www.rightmove.co.uk/properties/api/soldProperty/transactionHistory")!

    public var userAgent: String
    /// Raw `Cookie` header value, if the caller has a Rightmove session.
    public var cookie: String?
    public var timeout: TimeInterval

    public init(
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
        cookie: String? = nil,
        timeout: TimeInterval = 30.0
    ) {
        self.userAgent = userAgent
        self.cookie = cookie
        self.timeout = timeout
    }

    public enum Failure: Error, CustomStringConvertible {
        case notHTTP
        case httpError(Int)

        public var description: String {
            switch self {
            case .notHTTP:          return "Sold-history response was not HTTP"
            case .httpError(let s): return "Sold-history HTTP error \(s)"
            }
        }
    }

    /// Fetch the sold transaction history for a property.
    /// - Parameters:
    ///   - deliveryPointId: Royal Mail delivery-point id from the page model.
    ///   - encId: the page model's encrypted id (raw, not pre-encoded).
    ///   - propertyID: optional listing id, used only for the `Referer` header.
    public func history(deliveryPointId: String, encId: String,
                        propertyID: Int? = nil) async throws -> SoldPropertyHistory {
        // Build the query manually so encId's "=" padding is percent-encoded to
        // match the browser request (URLComponents leaves "=" literal in values).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let enc = encId.addingPercentEncoding(withAllowedCharacters: allowed) ?? encId
        let dpid = deliveryPointId.addingPercentEncoding(withAllowedCharacters: allowed) ?? deliveryPointId
        let url = URL(string: "\(Self.endpoint.absoluteString)?deliveryPointId=\(dpid)&encId=\(enc)")!

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let propertyID {
            request.setValue("https://www.rightmove.co.uk/properties/\(propertyID)",
                             forHTTPHeaderField: "Referer")
        }
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw Failure.httpError(http.statusCode) }
        return try Self.parse(data: data)
    }

    /// Decode the response. Pure and offline so it can be unit-tested.
    public static func parse(data: Data) throws -> SoldPropertyHistory {
        try JSONDecoder().decode(SoldPropertyHistory.self, from: data)
    }
}
