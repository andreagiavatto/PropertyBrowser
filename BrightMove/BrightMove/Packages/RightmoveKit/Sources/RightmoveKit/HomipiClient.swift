import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches a property's Homipi profile once the full address is known.
///
/// City-agnostic resolution off the postcode page alone: Homipi's property URLs
/// embed a `{city}` path segment we can't reliably derive, so we fetch the
/// postcode page (which needs no city) and read the matching property's listing
/// directly — the postcode page carries each property's estimate (or price range
/// + confidence), value change and last-sold facts inline, so there's no need to
/// follow the link to the detail page. All parsing lives in `HomipiParser`; this
/// type only does the fetching and maps failures to a `HomipiError` the UI can
/// degrade on.
///
/// Like `LandCValuationClient`/`PATMAClient`, it sends a realistic `User-Agent`
/// and accepts a soft Cloudflare challenge as "unavailable" rather than throwing
/// loudly — the parsed page has no embedded JSON to sanity-check against, so we
/// detect the known bot-wall markers explicitly.
public struct HomipiClient: Sendable {
    public var userAgent: String
    public var timeout: TimeInterval
    /// Safety cap on how many postcode-page pages to walk while hunting for the
    /// property's link. Dense postcodes paginate (10 per page); this bounds the
    /// worst case (a property not on Homipi) to a sane number of requests.
    public var maxPostcodePages: Int

    public init(
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        timeout: TimeInterval = 30.0,
        maxPostcodePages: Int = 12
    ) {
        self.userAgent = userAgent
        self.timeout = timeout
        self.maxPostcodePages = maxPostcodePages
    }

    /// Resolve and parse the Homipi report for a resolved single-line address +
    /// postcode. Throws `HomipiError` at each step it can't complete.
    ///
    /// Homipi's postcode page is paginated (10 properties per page) and dense
    /// postcodes run to many pages, so we can't assume the property is on page 1.
    /// We fetch page 1, learn the page count, and walk subsequent pages until the
    /// address slug turns up — parsing that listing in place and stopping as soon
    /// as it does.
    public func fetchReport(resolvedAddress: String?, postcode: String?) async throws -> HomipiReport {
        guard let slug = HomipiParser.propertySlug(fromAddress: resolvedAddress),
              let postcode = postcode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !postcode.isEmpty,
              let firstPageURL = HomipiParser.postcodePageURL(postcode: postcode)
        else { throw HomipiError.insufficientInput }

        let firstHTML = try await fetchHTML(firstPageURL)
        if let report = HomipiParser.parseListing(inPostcodeHTML: firstHTML, matchingSlug: slug) {
            return report
        }

        let lastPage = min(HomipiParser.lastPageNumber(inPostcodeHTML: firstHTML), maxPostcodePages)
        if lastPage >= 2 {
            for page in 2...lastPage {
                guard let pageURL = HomipiParser.postcodePageURL(postcode: postcode, page: page)
                else { continue }
                let html = try await fetchHTML(pageURL)
                if let report = HomipiParser.parseListing(inPostcodeHTML: html, matchingSlug: slug) {
                    return report
                }
            }
        }
        throw HomipiError.notFound
    }

    // MARK: - Fetch

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw HomipiError.network("Couldn't reach Homipi.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw HomipiError.network("Homipi response was not HTTP.")
        }
        let html = String(decoding: data, as: UTF8.self)
        if let reason = Self.challengeReason(html: html, status: http.statusCode) {
            throw HomipiError.challenged(reason)
        }
        guard (200...299).contains(http.statusCode) else {
            throw HomipiError.network("Homipi error \(http.statusCode).")
        }
        return html
    }

    /// Explicit bot-wall detection. Unlike `ChallengeDetector`, we don't use the
    /// "no embedded JSON" heuristic — Homipi pages are plain server-rendered HTML
    /// with no page model — so we key only off the known Cloudflare markers and
    /// blocking status codes.
    ///
    /// Marker choice matters: Cloudflare injects its `challenge-platform` JS
    /// (`/cdn-cgi/challenge-platform/…`) and Turnstile widgets into *ordinary*
    /// pages, not just interstitials, so matching on those substrings flags every
    /// successful fetch as a challenge. We therefore key only off strings unique
    /// to an actual block page (the "Just a moment…" interstitial title, the
    /// legacy verification box, the `_cf_chl_opt` challenge bootstrap, and the
    /// "enable JavaScript and cookies" gate).
    static func challengeReason(html: String, status: Int) -> String? {
        let markers = ["Just a moment...", "cf-browser-verification",
                       "Attention Required! | Cloudflare",
                       "Enable JavaScript and cookies to continue", "_cf_chl_opt"]
        for m in markers where html.contains(m) { return "matched “\(m)”" }
        switch status {
        case 403: return "HTTP 403 — typical bot block"
        case 503: return "HTTP 503 — Cloudflare interstitial"
        case 429: return "HTTP 429 — rate limited"
        default:  return nil
        }
    }
}

/// Exposes Homipi's own price estimate to the valuation stack, alongside L&C.
/// Reuses `HomipiClient.fetchReport` (the detail-view section fetches the
/// postcode page independently — a deliberate double fetch, accepted for full
/// independence between the two consumers), then maps the report's
/// estimate/range/confidence onto a `Valuation`.
public struct HomipiValuationProvider: ValuationProvider {
    public let source = HomipiReport.source

    private let client: HomipiClient

    public init(client: HomipiClient = HomipiClient()) {
        self.client = client
    }

    public func estimate(for query: ValuationQuery) async throws -> Valuation {
        guard let address = Self.recompose(query),
              query.postcode?.isEmpty == false else {
            throw ValuationError.insufficientInput
        }

        let report: HomipiReport
        do {
            report = try await client.fetchReport(resolvedAddress: address,
                                                  postcode: query.postcode)
        } catch let e as HomipiError {
            switch e {
            case .insufficientInput: throw ValuationError.insufficientInput
            case .notFound, .parse:  throw ValuationError.noEstimate
            case .challenged(let m): throw ValuationError.network("Homipi unavailable (\(m)).")
            case .network(let m):    throw ValuationError.network(m)
            }
        }

        guard let range = report.valueRange else { throw ValuationError.noEstimate }
        return Valuation(source: source, value: range, rent: nil)
    }

    /// Rebuild a single-line address from the decomposed query when the original
    /// wasn't carried through — covers the common "{number} {street}" case;
    /// named-building flats are best served by `query.singleLine`.
    private static func recompose(_ q: ValuationQuery) -> String? {
        var parts: [String] = []
        if let sub = q.subBuildingName?.trimmingCharacters(in: .whitespaces), !sub.isEmpty {
            parts.append(sub)
        }
        let numberStreet = [q.buildingNumber, q.street]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !numberStreet.isEmpty { parts.append(numberStreet) }
        let line = parts.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }
}
