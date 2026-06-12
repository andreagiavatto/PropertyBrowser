import Foundation

/// Decoded `propertyData` from a Rightmove property-detail page
/// (`window.__PAGE_MODEL`, flatted-encoded).
public struct PropertyDetail: Decodable {
    public let id: LossyNumber
    /// Encrypted id from the page model; pairs with `address.deliveryPointId`
    /// to fetch the property's sold-price history (`SoldHistoryClient`).
    public let encId: String?
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
    /// Floor-area figures Rightmove reports for the listing (usually one `sqft`
    /// and one `sqm` entry). Absent when the agent didn't supply a size.
    public let sizings: [PropertySizing]?
    /// e.g. ["SOLD_STC"], ["UNDER_OFFER"]; empty/absent when available.
    public let tags: [String]?

    public var propertyID: Int? { id.int }

    /// Authoritative floor area in square metres taken straight from the
    /// listing's `sizings`, or `nil` when the listing reports no usable size.
    /// Prefers an explicit square-metre figure; otherwise converts square feet
    /// (1 sq ft = 0.092903 m²). Use this in preference to reading the floorplan
    /// image, which can mis-OCR.
    ///
    /// `sizings` can also carry land units — real pages include "ha" (hectares)
    /// and "ac" (acres) alongside "sqm"/"sqft" — so units are matched exactly
    /// rather than by substring, and anything that isn't a building floor area
    /// is ignored.
    public var floorAreaSqM: Double? {
        guard let sizings else { return nil }

        func size(unit: String) -> Double? {
            guard let s = sizings.first(where: { ($0.unit ?? "").lowercased() == unit }) else { return nil }
            // minimumSize is the representative value (min == max for a single
            // figure); fall back to whichever side is present.
            let v = s.minimumSize?.double ?? s.maximumSize?.double
            return (v ?? 0) > 0 ? v : nil
        }

        if let sqm = size(unit: "sqm") { return sqm }
        if let sqft = size(unit: "sqft") { return sqft * 0.092903 }
        return nil
    }

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
    /// Royal Mail delivery-point id; pairs with `PropertyDetail.encId` for the
    /// sold-history API.
    public let deliveryPointId: LossyNumber?

    /// Full postcode ("N8" + "7RA" → "N8 7RA"), when both parts are present.
    public var fullPostcode: String? {
        guard let out = outcode, !out.isEmpty, let inc = incode, !inc.isEmpty else { return nil }
        return "\(out) \(inc)"
    }
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

/// One floor-area figure from `propertyData.sizings`, e.g.
/// `{ "unit": "sqm", "minimumSize": 85, "maximumSize": 85 }`.
public struct PropertySizing: Decodable {
    /// Rightmove's unit token, typically "sqft" or "sqm".
    public let unit: String?
    public let minimumSize: LossyNumber?
    public let maximumSize: LossyNumber?
}

public struct PropertyText: Decodable {
    public let description: String?
    public let propertyPhrase: String?
    public let shortDescription: String?
    public let pageTitle: String?
}

// MARK: - Computed helpers

extension ListingHistory {
    /// Parse the date embedded in strings like "Added on 22/05/2026" or "Reduced on 01/06/2026".
    public var parsedDate: Date? {
        guard let reason = listingUpdateReason else { return nil }
        // Extract dd/mm/yyyy
        let pattern = #"(\d{2}/\d{2}/\d{4})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason)),
              let range = Range(match.range(at: 1), in: reason) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        formatter.locale = Locale(identifier: "en_GB")
        return formatter.date(from: String(reason[range]))
    }

    /// e.g. "Added" or "Reduced"
    public var verb: String? {
        guard let reason = listingUpdateReason else { return nil }
        return reason.components(separatedBy: " ").first
    }
}

extension PropertyDetail {
    /// The date the listing first appeared, parsed from listingHistory.
    public var listingAddedDate: Date? { listingHistory?.parsedDate }
}
