import Foundation
import SwiftData

/// Whether the stored address is the resolver's best guess or a user-verified
/// choice. Stored raw for SwiftData stability.
public enum AddressConfirmation: String, Codable, Sendable {
    case unconfirmed
    case confirmed
}

/// A single candidate address persisted alongside a `ResolvedAddress`. Codable
/// so the ranked list survives as JSON; mirrors the app's view of a scored
/// EPC match plus its geocoded Street View link.
public struct StoredCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: String { uprn ?? address }
    public var address: String
    public var postcode: String?
    public var uprn: String?
    public var score: Double
    public var matchedSignals: [String]
    public var streetViewURLString: String?
    /// Link to the property's Rightmove house-prices page, where its previous
    /// for-sale listings can be viewed. A precise `/house-prices/details/{uuid}`
    /// link when we can pin the property, otherwise the postcode page.
    public var rightmoveHistoryURLString: String?

    public init(address: String, postcode: String? = nil, uprn: String? = nil,
                score: Double, matchedSignals: [String] = [],
                streetViewURLString: String? = nil,
                rightmoveHistoryURLString: String? = nil) {
        self.address = address
        self.postcode = postcode
        self.uprn = uprn
        self.score = score
        self.matchedSignals = matchedSignals
        self.streetViewURLString = streetViewURLString
        self.rightmoveHistoryURLString = rightmoveHistoryURLString
    }

    public var streetViewURL: URL? { streetViewURLString.flatMap(URL.init(string:)) }
    public var rightmoveHistoryURL: URL? { rightmoveHistoryURLString.flatMap(URL.init(string:)) }
}

/// Cached result of resolving a Rightmove listing to a real address. Keyed by
/// `propertyID` and decoupled from `PinnedProperty` — listings are resolved
/// whether or not they're pinned.
@Model
public final class ResolvedAddress {
    @Attribute(.unique) public var propertyID: Int

    /// The committed address: the top candidate (auto-saved, `unconfirmed`)
    /// until the user picks one (`confirmed`).
    public var resolvedAddress: String?
    public var postcode: String?
    public var uprn: String?

    public var confirmationRaw: String
    /// JSON-encoded `[StoredCandidate]`, ranked best-first.
    public var candidatesJSON: Data?
    /// Resolution method, for future provenance ("epc", later "epc+lr", …).
    public var method: String

    public var resolvedAt: Date
    public var confirmedAt: Date?

    public init(propertyID: Int,
                candidates: [StoredCandidate],
                method: String = "epc",
                resolvedAt: Date = Date()) {
        self.propertyID = propertyID
        self.method = method
        self.resolvedAt = resolvedAt
        self.confirmationRaw = AddressConfirmation.unconfirmed.rawValue
        self.candidatesJSON = nil
        self.setCandidates(candidates)
    }

    // MARK: Derived accessors

    public var confirmation: AddressConfirmation {
        get { AddressConfirmation(rawValue: confirmationRaw) ?? .unconfirmed }
        set { confirmationRaw = newValue.rawValue }
    }

    public var candidates: [StoredCandidate] {
        guard let data = candidatesJSON else { return [] }
        return (try? JSONDecoder().decode([StoredCandidate].self, from: data)) ?? []
    }

    /// Replace the ranked candidates and auto-promote the top one as the
    /// (unconfirmed) resolved address.
    public func setCandidates(_ list: [StoredCandidate]) {
        candidatesJSON = try? JSONEncoder().encode(list)
        if confirmation == .unconfirmed, let top = list.first {
            resolvedAddress = top.address
            postcode = top.postcode
            uprn = top.uprn
        }
    }

    /// Commit a user-chosen candidate as the confirmed address.
    public func confirm(_ candidate: StoredCandidate, at date: Date = Date()) {
        resolvedAddress = candidate.address
        postcode = candidate.postcode
        uprn = candidate.uprn
        confirmation = .confirmed
        confirmedAt = date
    }
}
