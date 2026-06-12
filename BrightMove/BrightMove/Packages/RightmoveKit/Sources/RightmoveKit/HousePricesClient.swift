import Foundation

/// Resolves a link to a property's Rightmove house-prices page (where its
/// previous for-sale listings can be viewed) for properties that *aren't*
/// resolved via the sold-history path — i.e. EPC-only matches, which carry no
/// `soldPropertyUrlPath`.
///
/// Strategy: look up the postcode's `locationId` via the typeahead, fetch the
/// house-prices postcode page, and match the resolved address to one of its
/// cards to get the precise `/house-prices/details/{uuid}` link. When no single
/// card matches, it degrades to the postcode page URL so a link is always
/// offered. All page parsing/matching lives in `HousePricesLink`.
public struct HousePricesClient: Sendable {
    private let client: RightmoveClient

    public init(client: RightmoveClient = RightmoveClient()) {
        self.client = client
    }

    /// Best house-prices link for a single resolved address + postcode: the
    /// pinned `details/{uuid}` URL, else the postcode page, else nil.
    public func historyURL(resolvedAddress: String, postcode: String) async -> URL? {
        await links(for: [(address: resolvedAddress, postcode: postcode)]).first ?? nil
    }

    /// Batch variant: resolves links for several addresses, fetching each
    /// distinct postcode page at most once. The result is aligned to `inputs`.
    public func links(for inputs: [(address: String, postcode: String)]) async -> [URL?] {
        var byPostcode: [String: [Int]] = [:]
        for (i, input) in inputs.enumerated() where !input.postcode.isEmpty {
            byPostcode[input.postcode, default: []].append(i)
        }

        var out = [URL?](repeating: nil, count: inputs.count)
        for (postcode, indices) in byPostcode {
            let page = await page(forPostcode: postcode)
            let cards = page.html.map { HousePricesLink.parseCards(html: $0) } ?? []
            for i in indices {
                if let card = HousePricesLink.matchCard(cards, to: inputs[i].address),
                   let url = card.detailURL {
                    out[i] = url            // pinned to the exact property
                } else {
                    out[i] = page.url       // degrade to the postcode page
                }
            }
        }
        return out
    }

    /// Fetch a postcode's house-prices page. Returns the page URL (whenever it
    /// can be built) plus its HTML (nil when the fetch failed or was challenged,
    /// in which case the caller still has the URL to degrade to).
    private func page(forPostcode postcode: String) async -> (url: URL?, html: String?) {
        var locationType: String?
        var locationId: String?
        if let suggestions = try? await client.fetchLocationSuggestions(query: postcode),
           let match = suggestions.first(where: { $0.locationIdentifier.hasPrefix("POSTCODE^") })
                    ?? suggestions.first,
           let split = HousePricesLink.splitLocationIdentifier(match.locationIdentifier) {
            locationType = split.type
            locationId = split.id
        }

        guard let url = HousePricesLink.postcodePageURL(
            postcode: postcode, locationType: locationType, locationId: locationId) else {
            return (nil, nil)
        }
        let html = try? await client.fetchHTML(url)
        return (url, html)
    }
}
