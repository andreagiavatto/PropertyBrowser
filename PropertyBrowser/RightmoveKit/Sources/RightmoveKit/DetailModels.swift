import Foundation

/// Decoded `propertyData` from a Rightmove property-detail page
/// (`window.__PAGE_MODEL`, flatted-encoded).
public struct PropertyDetail: Decodable {
    public let id: LossyNumber
    public let status: ListingStatus?
    public let prices: DetailPrices?
    public let address: Address?
    public let listingHistory: ListingHistory?
    public let keyFeatures: [String]?
    public let images: [DetailImage]?
    public let floorplans: [DetailImage]?
    public let location: GeoLocation?
    public let bedrooms: LossyNumber?
    public let bathrooms: LossyNumber?
    public let propertySubType: String?
    public let transactionType: String?
    public let tenure: Tenure?
    public let text: PropertyText?
    /// e.g. ["SOLD_STC"], ["UNDER_OFFER"]; empty/absent when available.
    public let tags: [String]?

    public var propertyID: Int? { id.int }

    /// Unified market state, combining `tags` (Sold STC / Under Offer) and
    /// `status` (full removal).
    public var listingState: ListingState {
        ListingState.derive(
            archived: status?.archived,
            published: status?.published,
            tags: tags,
            displayStatus: nil
        )
    }

    /// True when the listing has been taken off the market entirely.
    public var isDelisted: Bool { listingState == .delisted }
}

public struct ListingStatus: Decodable {
    public let published: Bool?
    public let archived: Bool?
}

public struct DetailPrices: Decodable {
    public let primaryPrice: String?
    public let secondaryPrice: String?
    public let displayPriceQualifier: String?
    public let pricePerSqFt: String?
}

public struct Address: Decodable {
    public let displayAddress: String?
    public let outcode: String?
    public let incode: String?
    public let countryCode: String?
    public let ukCountry: String?
}

public struct ListingHistory: Decodable {
    /// On the detail page this is a human string, e.g. "Added on 22/05/2026"
    /// or "Reduced on 01/06/2026".
    public let listingUpdateReason: String?
}

public struct DetailImage: Decodable {
    public let url: String?
    public let caption: String?
    public let type: String?
    public let resizedImageUrls: ResizedImageUrls?

    /// A reasonably sized URL for a gallery, falling back to the full image.
    public var galleryURLString: String? {
        resizedImageUrls?.size656x437 ?? url
    }
}

public struct ResizedImageUrls: Decodable {
    public let size135x100: String?
    public let size476x317: String?
    public let size656x437: String?
}

public struct Tenure: Decodable {
    public let tenureType: String?
}

public struct PropertyText: Decodable {
    public let description: String?
    public let propertyPhrase: String?
    public let shortDescription: String?
    public let pageTitle: String?
}
