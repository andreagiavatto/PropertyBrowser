import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Valuation provider backed by L&C's (London & Country) public house-price
/// calculator.
///
/// This mirrors what the browser does on `landc.co.uk/mortgages/house-price-
/// calculator`: it POSTs a `{ calculator, input }` envelope to the site's
/// same-origin proxy `…/api/calculatorhttptrigger`, which unwraps it and
/// forwards `{ SubBuildingName, Street, Postcode }` to L&C's integration host.
/// We hit the proxy (not the integration host) because that's the contract the
/// site exposes to callers — but it does light browser sniffing, so we send a
/// realistic `Origin`/`Referer`/`User-Agent`, as `PATMAClient` already does.
///
/// The endpoint is undocumented and private, so every failure mode maps to a
/// `ValuationError` the UI can degrade on rather than surfacing loudly.
public struct LandCValuationClient: ValuationProvider {
    public static let endpoint = URL(string:
        "https://www.landc.co.uk/api/calculatorhttptrigger")!

    public let source = "L&C"

    public var userAgent: String
    public var timeout: TimeInterval

    public init(
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        timeout: TimeInterval = 30.0
    ) {
        self.userAgent = userAgent
        self.timeout = timeout
    }

    // MARK: - Wire types

    /// Request envelope: `{"calculator":"houseprice","input":{…}}`.
    ///
    /// L&C's input has a `Number` (house number) and a separate `SubBuildingName`
    /// (flat designator). Both are optional on the wire — a house sends only
    /// `Number`, a flat sends both — so they're encoded only when present.
    struct Request: Encodable {
        let calculator = "houseprice"
        let input: Input
        struct Input: Encodable {
            let Number: String?
            let SubBuildingName: String?
            let Street: String
            let Postcode: String
        }
    }

    /// Proxy response. We only care about `result`; `url`/`body` are echoes.
    struct Response: Decodable {
        let result: Result?
        struct Result: Decodable {
            let PropertyValue: Int?
            let ValuationUpper: Int?
            let ValuationLower: Int?
            let MonthlyRental: Int?
            let MonthlyRentalUpper: Int?
            let MonthlyRentalLower: Int?
        }
    }

    // MARK: - Provider

    public func estimate(for query: ValuationQuery) async throws -> Valuation {
        // Street + postcode are mandatory; we also need at least one locator
        // within the street — a house number, a flat designator, or both.
        let number = query.buildingNumber?.trimmingCharacters(in: .whitespaces).nonEmpty
        let flat   = query.subBuildingName?.trimmingCharacters(in: .whitespaces).nonEmpty
        guard let street = query.street?.trimmingCharacters(in: .whitespaces).nonEmpty,
              let postcode = query.postcode?.trimmingCharacters(in: .whitespaces).nonEmpty,
              number != nil || flat != nil
        else {
            throw ValuationError.insufficientInput
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Browser-like signals the proxy sniffs for.
        request.setValue("https://www.landc.co.uk", forHTTPHeaderField: "Origin")
        request.setValue("https://www.landc.co.uk/mortgages/house-price-calculator",
                         forHTTPHeaderField: "Referer")

        request.httpBody = try Self.requestBody(number: number, flat: flat,
                                                street: street, postcode: postcode)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ValuationError.network("Couldn't reach the valuation service.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ValuationError.network("Valuation response was not HTTP.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ValuationError.network("Valuation service error \(http.statusCode).")
        }

        return try Self.valuation(from: data, source: source)
    }

    // MARK: - Request encoding (pure, offline — unit-testable)

    /// Encode the `{calculator, input}` body. `Number`/`SubBuildingName` are
    /// omitted when nil, so a house sends only `Number` and a flat sends both.
    static func requestBody(number: String?, flat: String?,
                            street: String, postcode: String) throws -> Data {
        let body = Request(input: .init(
            Number: number, SubBuildingName: flat, Street: street, Postcode: postcode))
        return try JSONEncoder().encode(body)
    }

    // MARK: - Parsing (pure, offline — unit-testable)

    /// Decode and validate a proxy response into a `Valuation`. Throws
    /// `.noEstimate` when the figures are missing or non-positive (the proxy can
    /// echo back a zeroed result for an address it can't place).
    static func valuation(from data: Data, source: String) throws -> Valuation {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ValuationError.network("Couldn't read the valuation response.")
        }

        guard let r = decoded.result,
              let value = r.PropertyValue, value > 0,
              let upper = r.ValuationUpper, upper > 0,
              let lower = r.ValuationLower, lower > 0
        else {
            throw ValuationError.noEstimate
        }

        // Rent rides along only when all three figures are present and positive.
        var rent: MoneyRange?
        if let rMid = r.MonthlyRental, rMid > 0,
           let rUp = r.MonthlyRentalUpper, rUp > 0,
           let rLo = r.MonthlyRentalLower, rLo > 0 {
            rent = MoneyRange(lower: rLo, mid: rMid, upper: rUp)
        }

        return Valuation(
            source: source,
            value: MoneyRange(lower: lower, mid: value, upper: upper),
            rent: rent
        )
    }
}

private extension String {
    /// Self when it has non-whitespace content, else nil.
    var nonEmpty: String? { isEmpty ? nil : self }
}
