import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Date parsing

/// EPC dates arrive either as a bare `yyyy-MM-dd` or an ISO8601 datetime
/// (with or without fractional seconds). Parse all three, UTC, locale-independent.
enum EPCDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let d = isoFractional.date(from: raw) { return d }
        if let d = iso.date(from: raw) { return d }
        return day.date(from: raw)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private func epcNonEmpty(_ s: String?) -> String? {
    guard let s else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

// MARK: - Search result (summary)

/// One row from the `/api/domestic/search` endpoint. This is a *summary*: it has
/// no floor area, property type, built form, or room count — those live only on
/// the per-certificate detail endpoint (`certificateDetail(number:)`).
public struct EPCSearchResult: Decodable, Equatable, Sendable {
    public let certificateNumber: String
    /// Combined single-line address, built from `addressLine1…4`.
    public let address: String?
    public let postcode: String?
    public let postTown: String?
    public let council: String?
    public let constituency: String?
    public let currentEnergyEfficiencyBand: String?
    public let registrationDate: Date?
    public let uprn: String?

    private enum CodingKeys: String, CodingKey {
        case certificateNumber
        case addressLine1, addressLine2, addressLine3, addressLine4
        case postcode, postTown, council, constituency
        case currentEnergyEfficiencyBand, registrationDate, uprn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        certificateNumber = epcNonEmpty(try? c.decode(String.self, forKey: .certificateNumber)) ?? ""

        let lines: [String] = [
            try? c.decode(String.self, forKey: .addressLine1),
            try? c.decode(String.self, forKey: .addressLine2),
            try? c.decode(String.self, forKey: .addressLine3),
            try? c.decode(String.self, forKey: .addressLine4),
        ].compactMap { epcNonEmpty($0) }
        address = lines.isEmpty ? nil : lines.joined(separator: ", ")

        postcode      = epcNonEmpty(try? c.decode(String.self, forKey: .postcode))
        postTown      = epcNonEmpty(try? c.decode(String.self, forKey: .postTown))
        council       = epcNonEmpty(try? c.decode(String.self, forKey: .council))
        constituency  = epcNonEmpty(try? c.decode(String.self, forKey: .constituency))
        currentEnergyEfficiencyBand = epcNonEmpty(try? c.decode(String.self, forKey: .currentEnergyEfficiencyBand))
        registrationDate = EPCDate.parse(epcNonEmpty(try? c.decode(String.self, forKey: .registrationDate)))

        if let n = (try? c.decode(Int.self, forKey: .uprn)) {
            uprn = String(n)
        } else {
            uprn = epcNonEmpty(try? c.decode(String.self, forKey: .uprn))
        }
    }

    /// Memberwise init for tests / synthetic data.
    public init(certificateNumber: String, address: String?, postcode: String?,
                postTown: String? = nil, council: String? = nil, constituency: String? = nil,
                currentEnergyEfficiencyBand: String? = nil, registrationDate: Date? = nil,
                uprn: String? = nil) {
        self.certificateNumber = certificateNumber
        self.address = address
        self.postcode = postcode
        self.postTown = postTown
        self.council = council
        self.constituency = constituency
        self.currentEnergyEfficiencyBand = currentEnergyEfficiencyBand
        self.registrationDate = registrationDate
        self.uprn = uprn
    }
}

/// Top-level shape of a search response: `{ "data": [...], "pagination": {...} }`.
struct EPCSearchResponse: Decodable {
    let data: [EPCSearchResult]
    let pagination: Pagination?

    struct Pagination: Decodable {
        let totalRecords: Int?
        let currentPage: Int?
        let totalPages: Int?
        let nextPage: Int?
        let prevPage: Int?
        let pageSize: Int?
    }
}

// MARK: - Certificate detail

/// The fields we need from the `/api/certificate` detail document. The full
/// document (see the RdSAP schema) is large and deeply nested; we decode only the
/// matchable bits via `.convertFromSnakeCase`.
///
/// `dwellingType` (e.g. "Mid-terrace house") is the human-readable string that
/// encodes both property family and built form, so we prefer it over the API's
/// integer-coded `property_type` / `built_form` enums.
struct EPCCertificateDetail: Decodable {
    let totalFloorArea: Double?
    let dwellingType: String?
    let habitableRoomCount: Int?
    let registrationDate: String?
    let uprn: Int?
    let addressLine1: String?
    let postcode: String?
}

/// Error envelope: `{ "data": { "error": "…" } }`. Note `data` is an *object*
/// here, not the array returned on success — so this is only decoded on non-2xx.
struct EPCErrorResponse: Decodable {
    struct Body: Decodable { let error: String }
    let data: Body
}

// MARK: - Rich certificate (search summary + detail, for matching)

/// An EPC certificate assembled for address matching: identity/address come from
/// the search summary, the physical signals (floor area, type, rooms) from the
/// detail endpoint. Not decoded directly from any single API response.
public struct EPCCertificate: Equatable, Sendable {
    /// Combined single-line address, e.g. "12, Acre Lane, London".
    public let address: String?
    public let postcode: String?
    /// Human-readable dwelling type, e.g. "Mid-terrace house", "Mid-floor flat".
    public let propertyType: String?
    /// Built form; for the new API this is also derived from the dwelling type.
    public let builtForm: String?
    /// Gross internal floor area in m².
    public let totalFloorArea: Double?
    public let habitableRooms: Int?
    public let lodgementDate: Date?
    public let uprn: String?
    /// Certificate number (RRN); kept for dedupe/debug.
    public let lmkKey: String?

    public init(address: String?, postcode: String?, propertyType: String?,
                builtForm: String?, totalFloorArea: Double?, habitableRooms: Int?,
                lodgementDate: Date?, uprn: String?, lmkKey: String? = nil) {
        self.address = address
        self.postcode = postcode
        self.propertyType = propertyType
        self.builtForm = builtForm
        self.totalFloorArea = totalFloorArea
        self.habitableRooms = habitableRooms
        self.lodgementDate = lodgementDate
        self.uprn = uprn
        self.lmkKey = lmkKey
    }
}

// MARK: - Client

/// Client for the MHCLG domestic EPC search + certificate APIs.
///
/// Auth is a Bearer token from the GOV.UK service. The new API has **no
/// outcode/prefix search** — `search(postcode:)` needs a *full* postcode — and
/// search results carry no physical data. The intended flow is:
///
/// 1. `search(address:)` → summary rows
/// 2. `EPCMatcher.shortlist(_:street:outcode:)` → the few candidates on the street
/// 3. `detailedCertificate(for:)` per candidate → floor area / type / rooms
/// 4. `EPCMatcher.rank(certificates:…)`
public struct EPCClient: Sendable {
    public static let searchEndpoint = URL(string:
        "https://api.get-energy-performance-data.communities.gov.uk/api/domestic/search")!
    public static let certificateEndpoint = URL(string:
        "https://api.get-energy-performance-data.communities.gov.uk/api/certificate")!

    /// The Bearer token issued by the GOV.UK service.
    public var token: String
    public var timeout: TimeInterval
    /// Defensive cap on search pagination. Each page is up to 5000 summary rows.
    public var maxPages: Int

    public init(token: String, timeout: TimeInterval = 30.0, maxPages: Int = 5) {
        self.token = token
        self.timeout = timeout
        self.maxPages = maxPages
    }

    public enum Failure: Error, CustomStringConvertible {
        case notHTTP
        case unauthorized
        case httpError(Int, message: String?)
        case notJSON(contentType: String)

        public var description: String {
            switch self {
            case .notHTTP:          return "EPC response was not HTTP"
            case .unauthorized:     return "EPC auth failed (check your Bearer token)"
            case .httpError(let s, let m):
                return m.map { "EPC error \(s): \($0)" } ?? "EPC HTTP error \(s)"
            case .notJSON(let ct):  return "EPC returned non-JSON body (Content-Type: \(ct)) — likely a redirect to the service homepage; check the endpoint host"
            }
        }
    }

    // MARK: Search

    /// All summary rows matching the given search parameters, following
    /// `pagination.nextPage` up to `maxPages`.
    ///
    /// NOTE: the API has no outcode/prefix search — `postcode` must be a *full*
    /// postcode or it returns 400. Callers with only an outcode should search by
    /// `address` and shortlist with `EPCMatcher.shortlist(_:street:outcode:)`.
    public func search(query items: [URLQueryItem]) async throws -> [EPCSearchResult] {
        var all: [EPCSearchResult] = []
        var page = 1

        for _ in 0..<maxPages {
            let url = searchURL(items: items, page: page)
            let data = try await get(url)
            if data.isEmpty { break }
            let decoded = try Self.parseSearch(data: data)
            all.append(contentsOf: decoded.data)
            guard let next = decoded.pagination?.nextPage, next != page, !decoded.data.isEmpty else { break }
            page = next
        }
        return all
    }

    /// Convenience over `search(query:)` for the common filters. At least one must
    /// be non-nil. `address` may be partial (e.g. a street name); `postcode` must
    /// be a full postcode; `uprn` is normalised to 12 digits. For
    /// council/constituency/efficiency_rating/date filters, build the
    /// `URLQueryItem`s directly and call `search(query:)`.
    public func search(address: String? = nil,
                       postcode: String? = nil,
                       uprn: String? = nil) async throws -> [EPCSearchResult] {
        var items: [URLQueryItem] = []
        if let address, !address.isEmpty { items.append(URLQueryItem(name: "address", value: address)) }
        if let postcode, !postcode.isEmpty { items.append(URLQueryItem(name: "postcode", value: postcode)) }
        if let uprn, let padded = Self.paddedUPRN(uprn) { items.append(URLQueryItem(name: "uprn", value: padded)) }
        return try await search(query: items)
    }

    private func searchURL(items: [URLQueryItem], page: Int) -> URL {
        var components = URLComponents(url: Self.searchEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items + [
            URLQueryItem(name: "page_size", value: "5000"),
            URLQueryItem(name: "current_page", value: String(page)),
        ]
        return components.url!
    }

    // MARK: Detail

    /// Fetch the full certificate document for a certificate number and extract
    /// the matchable fields. Internal: callers use `detailedCertificate(for:)`.
    func certificateDetail(number: String) async throws -> EPCCertificateDetail {
        var components = URLComponents(url: Self.certificateEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "certificate_number", value: number)]
        let data = try await get(components.url!)
        return try Self.parseDetail(data: data)
    }

    /// Search summary + detail merged into a single `EPCCertificate` for ranking.
    /// Address/postcode/uprn come from the (richer) summary; floor area, dwelling
    /// type and room count from the detail document.
    public func detailedCertificate(for result: EPCSearchResult) async throws -> EPCCertificate {
        let d = try await certificateDetail(number: result.certificateNumber)
        return EPCCertificate(
            address: result.address ?? epcNonEmpty(d.addressLine1),
            postcode: result.postcode ?? epcNonEmpty(d.postcode),
            // dwelling_type encodes both family ("house"/"flat") and form
            // ("mid-terrace"), so it feeds both sides of the type comparison.
            propertyType: d.dwellingType,
            builtForm: d.dwellingType,
            totalFloorArea: d.totalFloorArea,
            habitableRooms: d.habitableRoomCount,
            lodgementDate: result.registrationDate ?? EPCDate.parse(d.registrationDate),
            uprn: result.uprn ?? d.uprn.map(String.init),
            lmkKey: result.certificateNumber)
    }

    // MARK: Transport

    /// Authenticated GET with shared status/content-type handling.
    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            // Errors come back as { "data": { "error": "…" } }; surface the message.
            let message = (try? JSONDecoder().decode(EPCErrorResponse.self, from: data))?.data.error
            throw Failure.httpError(http.statusCode, message: message)
        }
        // A redirect to the service homepage returns 200 text/html. Reject any
        // non-JSON body so it can't be fed into the decoder as if it were data.
        if let ct = http.value(forHTTPHeaderField: "Content-Type"),
           !ct.localizedCaseInsensitiveContains("json") {
            throw Failure.notJSON(contentType: ct)
        }
        return data
    }

    // MARK: - Testable parsing

    /// Decode a search response (rows + pagination). Pure and offline.
    static func parseSearch(data: Data) throws -> EPCSearchResponse {
        try JSONDecoder().decode(EPCSearchResponse.self, from: data)
    }

    /// Decode a certificate detail document. Tolerates either a bare document or a
    /// `{ "data": { … } }` envelope.
    static func parseDetail(data: Data) throws -> EPCCertificateDetail {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        if let env = try? dec.decode(DetailEnvelope.self, from: data) { return env.data }
        return try dec.decode(EPCCertificateDetail.self, from: data)
    }

    private struct DetailEnvelope: Decodable { let data: EPCCertificateDetail }

    /// Normalise a UPRN to the 12-digit, zero-left-padded form the API expects.
    /// Returns nil if there are no digits, or as-is if already ≥12 digits.
    static func paddedUPRN(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        guard digits.count < 12 else { return digits }
        return String(repeating: "0", count: 12 - digits.count) + digits
    }
}
