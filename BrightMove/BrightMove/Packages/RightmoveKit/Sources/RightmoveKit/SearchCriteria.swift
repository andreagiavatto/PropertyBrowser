import Foundation

/// A single place returned by Rightmove's location typeahead. The
/// `locationIdentifier` is the opaque token a search URL needs (e.g.
/// "REGION^85386", "OUTCODE^2502", "POSTCODE^123456"); it's assembled from the
/// match's `type` and `id` as "TYPE^ID".
public struct LocationSuggestion: Decodable, Identifiable, Equatable, Sendable {
    public let locationIdentifier: String
    public let displayName: String

    public var id: String { locationIdentifier }

    public init(locationIdentifier: String, displayName: String) {
        self.locationIdentifier = locationIdentifier
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, displayName, locationIdentifier
    }

    /// Decodes a raw `los.rightmove.co.uk/typeahead` match
    /// (`{ "id": 85386, "type": "REGION", "displayName": "Richmond, Surrey" }`)
    /// and assembles the `TYPE^ID` identifier. Also tolerates a payload that
    /// already carries a `locationIdentifier`, for forward-compatibility.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""

        if let explicit = try? c.decode(String.self, forKey: .locationIdentifier), !explicit.isEmpty {
            self.locationIdentifier = explicit
            return
        }

        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        // `id` may arrive as a number or a string — normalise to its digits.
        let idString: String
        if let i = try? c.decode(Int.self, forKey: .id) {
            idString = String(i)
        } else if let s = try? c.decode(String.self, forKey: .id) {
            idString = s
        } else {
            idString = ""
        }
        self.locationIdentifier = type.isEmpty || idString.isEmpty ? "" : "\(type)^\(idString)"
    }
}

/// The envelope Rightmove's typeahead endpoint returns.
public struct TypeAheadResponse: Decodable, Sendable {
    public let matches: [LocationSuggestion]
}

/// Helpers for Rightmove's current location-lookup endpoint at
/// `los.rightmove.co.uk/typeahead`. Note this endpoint requires a
/// `Referer: https://www.rightmove.co.uk/` header to respond, and an
/// `Accept: application/json` header or it defaults to XML — both are set by
/// `RightmoveClient.fetchLocationSuggestions`.
public enum RightmoveTypeAhead {
    public static let base = "https://los.rightmove.co.uk/typeahead"

    /// The full typeahead URL for `query`, or nil for a blank query.
    public static func url(for query: String, limit: Int = 10) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: base)
        components?.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "exclude", value: ""),
        ]
        return components?.url
    }
}

/// How far beyond the chosen location to search. Maps to Rightmove's `radius`
/// query parameter (miles, as a decimal string; "0.0" means the area only).
public enum SearchRadius: String, CaseIterable, Identifiable, Codable, Sendable {
    case thisAreaOnly = "0.0"
    case quarter = "0.25"
    case half = "0.5"
    case one = "1.0"
    case three = "3.0"
    case five = "5.0"
    case ten = "10.0"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisAreaOnly: return "This area only"
        case .quarter: return "Within ¼ mile"
        case .half: return "Within ½ mile"
        case .one: return "Within 1 mile"
        case .three: return "Within 3 miles"
        case .five: return "Within 5 miles"
        case .ten: return "Within 10 miles"
        }
    }
}

/// Property type filter. Raw values are the tokens Rightmove's `propertyTypes`
/// query parameter expects.
public enum PropertyTypeFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case detached
    case semiDetached = "semi-detached"
    case terraced
    case flat
    case bungalow
    case parkHome = "park-home"
    case land

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .detached: return "Detached"
        case .semiDetached: return "Semi-detached"
        case .terraced: return "Terraced"
        case .flat: return "Flat / Apartment"
        case .bungalow: return "Bungalow"
        case .parkHome: return "Park home"
        case .land: return "Land"
        }
    }
}

/// How search results are ordered. Raw values are the codes Rightmove's
/// `sortType` query parameter expects. There is intentionally no "default"
/// case — a sort is always emitted, defaulting to `.highestPrice`, which
/// reproduces Rightmove's own out-of-the-box ordering.
public enum SortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case highestPrice = "2"
    case lowestPrice = "1"
    case newestListed = "6"
    case oldestListed = "10"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .highestPrice: return "Highest price"
        case .lowestPrice: return "Lowest price"
        case .newestListed: return "Newest listed"
        case .oldestListed: return "Oldest listed"
        }
    }
}

/// The user's structured search, assembled by the form and turned into a
/// Rightmove URL. Codable so it can be persisted and restored across launches.
public struct RightmoveSearchCriteria: Equatable, Codable, Sendable {
    /// The opaque Rightmove location token (e.g. "REGION^85386"). Empty until a
    /// location has been chosen from the typeahead.
    public var locationIdentifier: String
    /// Human-readable name of the chosen location, for display + restore.
    public var displayName: String
    public var radius: SearchRadius
    /// Minimum bedrooms ("0" == studio), or nil for no minimum.
    public var minBedrooms: String?
    /// Whole-pound price strings, or nil when unset.
    public var minPrice: String?
    public var maxPrice: String?
    public var propertyTypes: [PropertyTypeFilter]
    /// How results are ordered. Always set; defaults to `.highestPrice`.
    public var sortOrder: SortOrder

    public init(
        locationIdentifier: String = "",
        displayName: String = "",
        radius: SearchRadius = .thisAreaOnly,
        minBedrooms: String? = nil,
        minPrice: String? = nil,
        maxPrice: String? = nil,
        propertyTypes: [PropertyTypeFilter] = [],
        sortOrder: SortOrder = .highestPrice
    ) {
        self.locationIdentifier = locationIdentifier
        self.displayName = displayName
        self.radius = radius
        self.minBedrooms = minBedrooms
        self.minPrice = minPrice
        self.maxPrice = maxPrice
        self.propertyTypes = propertyTypes
        self.sortOrder = sortOrder
    }

    /// Tolerant decoding so criteria persisted before `sortOrder` existed still
    /// restore cleanly: a missing key falls back to `.highestPrice` (today's
    /// behaviour) rather than failing the whole decode and wiping the saved
    /// search. `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.locationIdentifier = try c.decode(String.self, forKey: .locationIdentifier)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.radius = try c.decode(SearchRadius.self, forKey: .radius)
        self.minBedrooms = try c.decodeIfPresent(String.self, forKey: .minBedrooms)
        self.minPrice = try c.decodeIfPresent(String.self, forKey: .minPrice)
        self.maxPrice = try c.decodeIfPresent(String.self, forKey: .maxPrice)
        self.propertyTypes = try c.decode([PropertyTypeFilter].self, forKey: .propertyTypes)
        self.sortOrder = try c.decodeIfPresent(SortOrder.self, forKey: .sortOrder) ?? .highestPrice
    }

    /// True once a location has been selected — the minimum a search needs.
    public var hasLocation: Bool { !locationIdentifier.isEmpty }
}
