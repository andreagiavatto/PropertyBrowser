import Foundation

/// Pure, network-free helpers for building a link to a property's Rightmove
/// house-prices page (where its previous for-sale listings can be viewed).
///
/// Two pieces are needed to deep-link to a single property:
///   1. the postcode index page URL (`/house-prices/{slug}.html?...`), and
///   2. the property's `/house-prices/details/{uuid}` card on that page.
///
/// Everything here operates on primitives so it unit-tests without the
/// networking layer (`RightmoveClient` lives above this). `HousePricesClient`
/// ties these together with the actual fetches.
public enum HousePricesLink {

    public static let host = "https://www.rightmove.co.uk"

    // MARK: - URL building

    /// Slugify a postcode for the house-prices path: "SW11 2EZ" → "sw11-2ez".
    public static func slug(forPostcode postcode: String) -> String? {
        let trimmed = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let slug = trimmed
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    /// Split a typeahead `locationIdentifier` ("POSTCODE^3704430") into the
    /// `locationType` / `locationId` pair the house-prices URL expects. Returns
    /// nil when the token isn't a `TYPE^ID` pair.
    public static func splitLocationIdentifier(
        _ identifier: String
    ) -> (type: String, id: String)? {
        let parts = identifier.split(separator: "^", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// The postcode index page, e.g.
    /// `/house-prices/sw11-2ez.html?locationType=POSTCODE&locationId=3704430&...`.
    /// `locationType`/`locationId` are optional — Rightmove will resolve the slug
    /// alone in most cases, but supplying them is more reliable.
    public static func postcodePageURL(
        postcode: String,
        locationType: String? = nil,
        locationId: String? = nil,
        pageNumber: Int = 1
    ) -> URL? {
        guard let slug = slug(forPostcode: postcode) else { return nil }
        var components = URLComponents(string: "\(host)/house-prices/\(slug).html")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "pageNumber", value: String(pageNumber)),
            URLQueryItem(name: "sortBy", value: "DEED_DATE"),
            URLQueryItem(name: "sortOrder", value: "DESC"),
        ]
        if let locationType, let locationId {
            items.append(URLQueryItem(name: "locationType", value: locationType))
            items.append(URLQueryItem(name: "locationId", value: locationId))
        }
        components?.queryItems = items
        return components?.url
    }

    // MARK: - Card parsing

    /// One property card scraped from the server-rendered house-prices page: its
    /// display address and the `/house-prices/details/{uuid}` link.
    public struct Card: Equatable, Sendable {
        public let address: String
        public let detailURLString: String

        public init(address: String, detailURLString: String) {
            self.address = address
            self.detailURLString = detailURLString
        }

        public var detailURL: URL? { URL(string: detailURLString) }
    }

    /// Extract the property cards from a house-prices postcode page. Each card is
    /// an anchor (`data-testid="propertyCard"`) whose `href` is the details link,
    /// immediately followed by an `<h2>` carrying the address.
    public static func parseCards(html: String) -> [Card] {
        let anchor = #"data-testid="propertyCard"\s+href="([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: anchor) else { return [] }
        let ns = html as NSString
        var cards: [Card] = []
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, let hrefRange = Range(m.range(at: 1), in: html) else { return }
            let href = String(html[hrefRange])
            // The address <h2> sits just after the anchor; scan a bounded window.
            let from = m.range.location + m.range.length
            let window = ns.substring(with: NSRange(
                location: from, length: min(800, ns.length - from)))
            guard let title = firstH2Text(in: window), !title.isEmpty else { return }
            cards.append(Card(address: title, detailURLString: href))
        }
        return cards
    }

    /// First `<h2>…</h2>` inner text in `html`, tags stripped and whitespace
    /// collapsed. Decodes the handful of HTML entities Rightmove emits.
    private static func firstH2Text(in html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"<h2[^>]*>(.*?)</h2>"#,
                                                options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        let inner = String(html[r])
        let stripped = inner.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Matching

    /// Pick the card matching `resolvedAddress` (house number + street within the
    /// postcode). Returns the single match, or nil when nothing matches or the
    /// result is ambiguous — callers degrade to the postcode page or ask the user.
    public static func matchCard(_ cards: [Card], to resolvedAddress: String) -> Card? {
        guard let target = paonAndStreet(resolvedAddress) else { return nil }
        let matches = cards.filter { card in
            guard let c = paonAndStreet(card.address) else { return false }
            return c.paon == target.paon && streetsMatch(c.street, target.street)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// The Primary Addressable Object Number (house number) + street of an
    /// address. The PAON is the numeric token immediately preceding the street;
    /// this deliberately ignores any SAON (flat/unit) so a house and its address
    /// string compare cleanly.
    static func paonAndStreet(_ address: String) -> (paon: String, street: String)? {
        guard let street = StreetName.parse(from: address) else { return nil }
        let tokens = StreetName.normalise(address).split(separator: " ").map(String.init)
        guard let streetFirst = StreetName.normalise(street).split(separator: " ").first
            .map(String.init),
              let streetIndex = tokens.firstIndex(of: streetFirst) else { return nil }
        // Nearest numeric token before the street start is the house number.
        for i in stride(from: streetIndex - 1, through: 0, by: -1) {
            if tokens[i].range(of: #"^\d+[a-z]?$"#, options: .regularExpression) != nil {
                return (tokens[i], street)
            }
        }
        return nil
    }

    /// Whether two parsed street names refer to the same street, tolerant of
    /// road-type abbreviations ("Rd" ⇄ "Road").
    static func streetsMatch(_ a: String, _ b: String) -> Bool {
        !StreetName.matchVariants(of: a).isDisjoint(with: StreetName.matchVariants(of: b))
    }
}
