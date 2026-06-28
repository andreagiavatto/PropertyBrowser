import Foundation
import SwiftData
import RightmoveKit

/// The kind of a recorded change. Stored as a raw string for SwiftData stability.
public enum PropertyEventKind: String, Codable, Sendable {
    case firstSeen
    case priceChange
    case statusChange
}

/// A property the user has pinned to track over time. Holds the latest known
/// state plus an append-only log of `events`.
@Model
public final class PinnedProperty {
    @Attribute(.unique) public var propertyID: Int

    public var displayAddress: String?
    public var bedrooms: Int?
    public var bathrooms: Int?
    public var propertySubType: String?
    /// First gallery image URL, cached so the watchlist card can show a thumbnail.
    public var thumbnailURLString: String?
    /// Whether the latest known update was a price reduction (card "Reduced" tag).
    public var isPriceReduced: Bool = false
    /// Human "Added/Reduced on …" text for the card footer.
    public var addedOrReduced: String?

    public var currentPriceAmount: Int?
    public var currentPriceDisplay: String?
    public var currentStateRaw: String

    public var pinnedAt: Date
    /// Last time a refresh successfully reached this property.
    public var lastSeenAt: Date?
    /// Last time a refresh ran for it (whether or not anything changed).
    public var lastCheckedAt: Date?
    /// The saved-search URL it was discovered through, if any.
    public var sourceSearchURL: String?

    @Relationship(deleteRule: .cascade, inverse: \PropertyEvent.property)
    public var events: [PropertyEvent] = []

    public init(snapshot: TrackedSnapshot, sourceSearchURL: String? = nil) {
        self.propertyID = snapshot.propertyID
        self.displayAddress = snapshot.displayAddress
        self.bedrooms = snapshot.bedrooms
        self.bathrooms = snapshot.bathrooms
        self.propertySubType = snapshot.propertySubType
        self.thumbnailURLString = snapshot.thumbnailURLString
        self.isPriceReduced = snapshot.isPriceReduced
        self.addedOrReduced = snapshot.addedOrReduced
        self.currentPriceAmount = snapshot.priceAmount
        self.currentPriceDisplay = snapshot.priceDisplay
        self.currentStateRaw = snapshot.state.rawValue
        self.pinnedAt = snapshot.capturedAt
        self.lastSeenAt = snapshot.capturedAt
        self.lastCheckedAt = snapshot.capturedAt
        self.sourceSearchURL = sourceSearchURL
    }

    public var currentState: ListingState {
        ListingState(rawValue: currentStateRaw) ?? .unknown
    }

    /// Reconstruct a snapshot of the currently stored state, for diffing.
    public var currentSnapshot: TrackedSnapshot {
        TrackedSnapshot(
            propertyID: propertyID,
            priceAmount: currentPriceAmount,
            priceDisplay: currentPriceDisplay,
            state: currentState,
            capturedAt: lastSeenAt ?? pinnedAt,
            displayAddress: displayAddress,
            bedrooms: bedrooms,
            bathrooms: bathrooms,
            propertySubType: propertySubType,
            thumbnailURLString: thumbnailURLString,
            isPriceReduced: isPriceReduced,
            addedOrReduced: addedOrReduced
        )
    }
}

/// A property the user has opened the detail view for. Keyed by `propertyID`
/// so it persists independently of whether the property is pinned, and used to
/// grey out "already looked at" pills on the map.
@Model
public final class ViewedProperty {
    @Attribute(.unique) public var propertyID: Int
    /// When the property was most recently opened.
    public var viewedAt: Date

    public init(propertyID: Int, viewedAt: Date = Date()) {
        self.propertyID = propertyID
        self.viewedAt = viewedAt
    }
}

/// One entry in a pinned property's history. Append-only.
@Model
public final class PropertyEvent {
    public var kindRaw: String
    public var date: Date

    public var fromAmount: Int?
    public var toAmount: Int?
    public var fromDisplay: String?
    public var toDisplay: String?

    public var fromStateRaw: String?
    public var toStateRaw: String?

    public var property: PinnedProperty?

    public init(
        kind: PropertyEventKind,
        date: Date,
        fromAmount: Int? = nil,
        toAmount: Int? = nil,
        fromDisplay: String? = nil,
        toDisplay: String? = nil,
        fromState: ListingState? = nil,
        toState: ListingState? = nil
    ) {
        self.kindRaw = kind.rawValue
        self.date = date
        self.fromAmount = fromAmount
        self.toAmount = toAmount
        self.fromDisplay = fromDisplay
        self.toDisplay = toDisplay
        self.fromStateRaw = fromState?.rawValue
        self.toStateRaw = toState?.rawValue
    }

    public var kind: PropertyEventKind { PropertyEventKind(rawValue: kindRaw) ?? .statusChange }
    public var fromState: ListingState? { fromStateRaw.flatMap(ListingState.init(rawValue:)) }
    public var toState: ListingState? { toStateRaw.flatMap(ListingState.init(rawValue:)) }

    public var isPriceReduction: Bool {
        kind == .priceChange && (toAmount ?? .max) < (fromAmount ?? .min)
    }
}
