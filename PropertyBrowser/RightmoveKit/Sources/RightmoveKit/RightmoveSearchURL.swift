import Foundation

/// Wraps a Rightmove search-results URL pasted by the user. The query string
/// already encodes the location and every filter, so a saved search is just
/// this URL. Used to build the paginated fetch URLs the tracker polls.
public struct RightmoveSearchURL: Equatable {
    public static let defaultBase = "https://www.rightmove.co.uk/property-for-sale/find.html"

    /// Scheme + host + path, without query (e.g. ".../property-for-sale/find.html").
    public let base: String
    /// All query items from the pasted URL, order preserved.
    public private(set) var queryItems: [URLQueryItem]

    public init?(string raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }

        if components.scheme == nil { components.scheme = "https" }
        if components.host == nil { components.host = "www.rightmove.co.uk" }

        let path = components.path.isEmpty ? "/property-for-sale/find.html" : components.path
        guard let scheme = components.scheme, let host = components.host else { return nil }
        self.base = "\(scheme)://\(host)\(path)"
        self.queryItems = components.queryItems ?? []
    }

    public var locationIdentifier: String? { value(for: "locationIdentifier") }
    public var searchLocation: String? { value(for: "searchLocation") }
    public var radius: String? { value(for: "radius") }
    public var propertyTypes: [String] { values(for: "propertyTypes") }
    public var minBedrooms: String? { value(for: "minBedrooms") }
    public var maxBedrooms: String? { value(for: "maxBedrooms") }
    public var minPrice: String? { value(for: "minPrice") }
    public var maxPrice: String? { value(for: "maxPrice") }

    /// Whether the search already includes Under Offer / Sold STC results.
    public var includesSSTC: Bool { value(for: "_includeSSTC") == "on" }

    // MARK: URL building

    /// A URL for the page starting at `index` (Rightmove pages in steps of 24).
    /// Always forces `_includeSSTC=on` so pinned properties remain visible once
    /// they go Under Offer or Sold STC.
    public func pageURL(index: Int) -> URL? {
        var items = queryItems.filter { $0.name != "index" && $0.name != "_includeSSTC" }
        items.append(URLQueryItem(name: "index", value: String(index)))
        items.append(URLQueryItem(name: "_includeSSTC", value: "on"))

        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        return components.url
    }

    /// The first page (index 0).
    public func firstPageURL() -> URL? { pageURL(index: 0) }

    /// Page indices needed to cover `resultCount` results, 24 per page,
    /// capped at Rightmove's hard limit of ~42 pages (1008 results).
    public func pageIndices(forResultCount count: Int, perPage: Int = 24) -> [Int] {
        guard count > 0 else { return [0] }
        let pages = min((count + perPage - 1) / perPage, 42)
        return (0..<pages).map { $0 * perPage }
    }

    // MARK: Helpers

    private func value(for name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    private func values(for name: String) -> [String] {
        queryItems.filter { $0.name == name }.compactMap { $0.value }
    }
}
