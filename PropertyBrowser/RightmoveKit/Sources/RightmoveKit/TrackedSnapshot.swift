import Foundation

/// A point-in-time capture of the fields we track for a property. Built from
/// either a search-results row or a detail page, so the diff logic doesn't care
/// which source a refresh came from. Pure value type — no persistence.
public struct TrackedSnapshot: Equatable, Sendable {
    public let propertyID: Int
    /// Numeric asking price in whole pounds, if it could be determined.
    public let priceAmount: Int?
    /// Human display price, e.g. "£800,000".
    public let priceDisplay: String?
    public let state: ListingState
    public let capturedAt: Date

    // Descriptive fields (carried so a pin can be created from a snapshot).
    public let displayAddress: String?
    public let bedrooms: Int?

    public init(
        propertyID: Int,
        priceAmount: Int?,
        priceDisplay: String?,
        state: ListingState,
        capturedAt: Date = Date(),
        displayAddress: String? = nil,
        bedrooms: Int? = nil
    ) {
        self.propertyID = propertyID
        self.priceAmount = priceAmount
        self.priceDisplay = priceDisplay
        self.state = state
        self.capturedAt = capturedAt
        self.displayAddress = displayAddress
        self.bedrooms = bedrooms
    }

    /// Extracts whole pounds from a display string like "£16,950,000" or
    /// "Offers in Excess of £800,000". Returns nil for non-numeric prices (POA).
    public static func parseAmount(_ display: String?) -> Int? {
        guard let display else { return nil }
        let digits = display.filter { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}

public extension TrackedSnapshot {
    /// Build from a search-results row. Returns nil if the id isn't an integer.
    init?(search p: SearchProperty, at date: Date = Date()) {
        guard let id = p.propertyID else { return nil }
        let display = p.price?.primaryDisplay
        self.init(
            propertyID: id,
            priceAmount: p.price?.amount?.int ?? TrackedSnapshot.parseAmount(display),
            priceDisplay: display,
            state: p.listingState,
            capturedAt: date,
            displayAddress: p.displayAddress,
            bedrooms: p.bedrooms?.int
        )
    }

    /// Build from a detail page. Returns nil if the id isn't an integer.
    init?(detail d: PropertyDetail, at date: Date = Date()) {
        guard let id = d.propertyID else { return nil }
        let display = d.prices?.primaryPrice
        self.init(
            propertyID: id,
            priceAmount: TrackedSnapshot.parseAmount(display),
            priceDisplay: display,
            state: d.listingState,
            capturedAt: date,
            displayAddress: d.address?.displayAddress,
            bedrooms: d.bedrooms?.int
        )
    }
}
