import Foundation

/// Decoded `props.pageProps.searchResults` from a Rightmove search-results page.
public struct SearchResultsPage: Decodable {
    public let resultCount: LossyNumber?
    public let properties: [SearchProperty]
    public let pagination: Pagination?
    public let searchParameters: SearchParameters?

    /// Properties with featured duplicates collapsed to one row each, keyed by
    /// the real Rightmove `propertyID`. A featured listing appears twice on a
    /// page (promoted copy + in-place copy); for tracking/diffing we want a
    /// single canonical snapshot per listing, so the non-featured (in-place)
    /// copy is preferred and the promoted duplicate dropped. Order is preserved
    /// by first appearance. Rows without an integer id are passed through
    /// unchanged (nothing to de-dupe them against).
    ///
    /// Use this for building `TrackedSnapshot`s; use `properties` for display,
    /// where the featured row is shown distinctly via `listingKey`.
    public var uniqueProperties: [SearchProperty] {
        var result: [SearchProperty] = []
        var indexByID: [Int: Int] = [:]
        for p in properties {
            guard let id = p.propertyID else { result.append(p); continue }
            if let existing = indexByID[id] {
                // Already seen this listing. Replace only if the kept copy is the
                // featured one and this copy is the canonical (non-featured) one.
                if result[existing].isFeatured && !p.isFeatured {
                    result[existing] = p
                }
            } else {
                indexByID[id] = result.count
                result.append(p)
            }
        }
        return result
    }
}

public struct Pagination: Decodable {
    public let total: LossyNumber?      // number of pages
    public let page: String?
    public let first: String?
    public let last: String?
    public let next: String?
}

public struct SearchParameters: Decodable {
    public let locationIdentifier: String?
    public let radius: String?
    public let index: String?
    public let sortType: String?
    public let numberOfPropertiesPerPage: String?
    public let propertyTypes: [String]?
    public let minBedrooms: String?
    public let maxBedrooms: String?
    public let minPrice: String?
    public let maxPrice: String?
}

/// A single property as it appears in a search-results listing.
public struct SearchProperty: Decodable {
    public let id: LossyNumber
    public let bedrooms: LossyNumber?
    public let bathrooms: LossyNumber?
    public let summary: String?
    public let displayAddress: String?
    public let propertySubType: String?
    public let price: Price?
    public let listingUpdate: ListingUpdate?
    /// Empty when available; "Under Offer" / "Sold STC" otherwise.
    public let displayStatus: String?
    public let transactionType: String?
    public let addedOrReduced: String?
    public let firstVisibleDate: String?
    public let location: GeoLocation?
    public let propertyUrl: String?
    public let propertyImages: PropertyImages?
    /// e.g. ["SOLD_STC"], ["UNDER_OFFER"]; empty/absent when available.
    public let tags: [String]?
    /// True for the promoted "featured" slot. A featured listing is repeated:
    /// it appears once at the top with this flag set and again in its normal
    /// position with the flag false, so the same `id` can occur twice on a page.
    public let featuredProperty: Bool?

    /// Stable Rightmove property id, if it decoded as an integer.
    /// Use this for pinning, navigation and building the listing URL — it is the
    /// real Rightmove id and is intentionally the SAME for both copies.
    public var propertyID: Int? { id.int }

    /// Whether this row is the promoted featured copy.
    public var isFeatured: Bool { featuredProperty ?? false }

    /// De-duplicating identity for list rendering. Combines the Rightmove id
    /// with the featured flag so the featured copy and the in-place copy of the
    /// same property get distinct keys (`"87848940-featured"` vs `"87848940"`).
    /// Use this for SwiftUI `ForEach(id:)`; use `propertyID` for everything that
    /// must address the real listing.
    public var listingKey: String {
        let base = propertyID.map(String.init) ?? "raw-\(id.description)"
        return isFeatured ? "\(base)-featured" : base
    }

    /// Unified market state from `displayStatus` and/or `tags`.
    public var listingState: ListingState {
        ListingState.derive(
            archived: nil,
            published: nil,
            tags: tags,
            displayStatus: displayStatus
        )
    }
}

public struct Price: Decodable {
    public let amount: LossyNumber?
    public let currencyCode: String?
    public let displayPrices: [DisplayPrice]?

    public var primaryDisplay: String? { displayPrices?.first?.displayPrice }
}

public struct DisplayPrice: Decodable {
    public let displayPrice: String?
    public let displayPriceQualifier: String?
}

public struct ListingUpdate: Decodable {
    /// "new", "price_reduced", "price_increased", etc.
    public let listingUpdateReason: String?
    public let listingUpdateDate: String?
}

public struct GeoLocation: Decodable {
    public let latitude: LossyNumber?
    public let longitude: LossyNumber?

    public var lat: Double? { latitude?.double }
    public var lng: Double? { longitude?.double }
}

public struct PropertyImages: Decodable {
    public let images: [SearchImage]?
}

public struct SearchImage: Decodable {
    public let srcUrl: String?
    public let url: String?
    public let caption: String?
}
