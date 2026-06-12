import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HM Land Registry Price Paid transaction for an address in a postcode.
/// `paon` (Primary Addressable Object Name) is the house number/name; `saon`
/// (Secondary…) is the flat/unit when present.
public struct PricePaidRecord: Equatable, Sendable {
    public let paon: String?
    public let saon: String?
    public let street: String?
    public let postcode: String?
    public let price: Int
    public let date: Date

    public init(paon: String?, saon: String?, street: String?, postcode: String?,
                price: Int, date: Date) {
        self.paon = paon
        self.saon = saon
        self.street = street
        self.postcode = postcode
        self.price = price
        self.date = date
    }

    public var year: Int? {
        Calendar(identifier: .iso8601).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: date).year
    }
}

/// Queries HM Land Registry's Price Paid Data SPARQL endpoint.
///
/// Uses an HTTP POST with a `application/sparql-query` body (avoids URL-length
/// limits) and requests `application/sparql-results+json`.
public struct LandRegistryClient: Sendable {
    public static let endpoint = URL(string:
        "https://landregistry.data.gov.uk/landregistry/query")!

    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30.0) {
        self.timeout = timeout
    }

    public enum Failure: Error, CustomStringConvertible {
        case notHTTP
        case httpError(Int)

        public var description: String {
            switch self {
            case .notHTTP:          return "Land Registry response was not HTTP"
            case .httpError(let s): return "Land Registry HTTP error \(s)"
            }
        }
    }

    /// All Price Paid transactions recorded for a postcode, oldest first.
    public func transactions(postcode: String) async throws -> [PricePaidRecord] {
        let query = Self.sparql(postcode: postcode)
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/sparql-query", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(query.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw Failure.httpError(http.statusCode) }
        return try Self.parse(data: data)
    }

    /// Build the SPARQL query for a postcode. The Price Paid store holds postcodes
    /// uppercased with a single space (e.g. "SW2 5SG").
    static func sparql(postcode: String) -> String {
        let pc = normalisePostcode(postcode)
        return """
        PREFIX lrppi: <http://landregistry.data.gov.uk/def/ppi/>
        PREFIX lrcommon: <http://landregistry.data.gov.uk/def/common/>
        SELECT ?paon ?saon ?street ?price ?date WHERE {
          ?addr lrcommon:postcode "\(pc)" .
          ?txn lrppi:propertyAddress ?addr ;
               lrppi:pricePaid ?price ;
               lrppi:transactionDate ?date .
          OPTIONAL { ?addr lrcommon:paon ?paon }
          OPTIONAL { ?addr lrcommon:saon ?saon }
          OPTIONAL { ?addr lrcommon:street ?street }
        }
        ORDER BY ?date
        """
    }

    /// Uppercase, collapse internal whitespace, and ensure a single space before
    /// the 3-character incode (e.g. "sw25sg" / "SW2  5SG" → "SW2 5SG").
    static func normalisePostcode(_ raw: String) -> String {
        let bare = raw.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
        guard bare.count > 3 else { return String(bare) }
        let outcode = bare.dropLast(3)
        let incode = bare.suffix(3)
        return String(outcode) + " " + String(incode)
    }

    // MARK: - Testable parsing

    /// Decode SPARQL 1.1 JSON results into Price Paid records, skipping rows that
    /// lack a usable price or date.
    public static func parse(data: Data) throws -> [PricePaidRecord] {
        let results = try JSONDecoder().decode(SPARQLResults.self, from: data)
        return results.results.bindings.compactMap { row -> PricePaidRecord? in
            guard let priceStr = row["price"]?.value, let price = Int(priceStr),
                  let dateStr = row["date"]?.value, let date = parseDate(dateStr) else {
                return nil
            }
            return PricePaidRecord(
                paon: row["paon"]?.value,
                saon: row["saon"]?.value,
                street: row["street"]?.value,
                postcode: row["postcode"]?.value,
                price: price,
                date: date)
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        // PPD dates are "yyyy-MM-dd" (sometimes with a trailing time component).
        let day = String(s.prefix(10))
        return dayFormatter.date(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Minimal SPARQL 1.1 JSON results envelope: `{ "results": { "bindings": [ {var: {"value": …}} ] } }`.
struct SPARQLResults: Decodable {
    let results: Bindings
    struct Bindings: Decodable { let bindings: [[String: Term]] }
    struct Term: Decodable { let value: String }
}
