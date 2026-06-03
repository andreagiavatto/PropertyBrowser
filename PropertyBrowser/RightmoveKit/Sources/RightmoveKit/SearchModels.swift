import Foundation

/// Decoded `props.pageProps.searchResults` from a Rightmove search-results page.
public struct SearchResultsPage: Decodable {
    public let resultCount: LossyNumber?
    public let properties: [SearchProperty]
    public let pagination: Pagination?
    public let searchParameters: SearchParameters?
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

    /// Stable Rightmove property id, if it decoded as an integer.
    public var propertyID: Int? { id.int }

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
