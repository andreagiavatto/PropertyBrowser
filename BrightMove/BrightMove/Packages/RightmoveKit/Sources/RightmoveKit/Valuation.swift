import Foundation

/// A money band returned by a valuation provider: a midpoint flanked by a
/// lower/upper estimate. All values are whole pounds (or whole pounds-per-month
/// for rent).
public struct MoneyRange: Equatable, Sendable {
    public let lower: Int
    public let mid: Int
    public let upper: Int

    public init(lower: Int, mid: Int, upper: Int) {
        self.lower = lower
        self.mid = mid
        self.upper = upper
    }
}

/// A normalised valuation result, decoupled from any one provider's response
/// shape. Rent is optional so providers that only return a sale estimate (most
/// of them) conform without inventing figures.
public struct Valuation: Equatable, Sendable, Identifiable {
    /// Provider name, e.g. "L&C". Doubles as the stable identity for list rows.
    public let source: String
    /// Estimated sale value in whole pounds, with its confidence band.
    public let value: MoneyRange
    /// Estimated monthly rent in whole pounds, when the provider supplies it.
    public let rent: MoneyRange?

    public var id: String { source }

    public init(source: String, value: MoneyRange, rent: MoneyRange? = nil) {
        self.source = source
        self.value = value
        self.rent = rent
    }
}

/// The inputs a provider may need to value a property. Providers take what they
/// require and signal `insufficientInput` when something mandatory is missing —
/// so the same query can be fanned out to every provider.
public struct ValuationQuery: Sendable {
    /// Building/house number, e.g. "52" or "12A" (L&C's `Number` field).
    public let buildingNumber: String?
    /// Sub-building / flat designator, e.g. "Flat C" (L&C's `SubBuildingName`).
    /// nil for a whole house.
    public let subBuildingName: String?
    /// Street name without number, e.g. "Felmersham Close".
    public let street: String?
    /// Full postcode, e.g. "SW4 7EU".
    public let postcode: String?

    public init(buildingNumber: String?, subBuildingName: String? = nil,
                street: String?, postcode: String?) {
        self.buildingNumber = buildingNumber
        self.subBuildingName = subBuildingName
        self.street = street
        self.postcode = postcode
    }

    /// Build a query from a resolved single-line address plus its postcode,
    /// reusing `StreetName` to pull the street and extracting the house number
    /// and any flat designator. Returns inputs that may still be partial —
    /// providers validate.
    public init(resolvedAddress: String?, postcode: String?) {
        self.buildingNumber = ValuationAddress.buildingNumber(from: resolvedAddress)
        self.subBuildingName = ValuationAddress.subBuildingName(from: resolvedAddress)
        self.street = StreetName.parse(from: resolvedAddress)
        self.postcode = postcode?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why a valuation couldn't be produced. Mirrors `ResolveOutcome`'s split so the
/// UI can treat "we didn't have enough to ask" differently from "the service
/// failed" or "the service had no answer".
public enum ValuationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Mandatory inputs were missing (no number / street / postcode), so no
    /// request was made.
    case insufficientInput
    /// The provider answered but with nothing usable (zero/absurd figures).
    case noEstimate
    /// Network, HTTP, or decoding failure. `message` is user-facing.
    case network(String)

    public var description: String {
        switch self {
        case .insufficientInput: return "Not enough address detail to estimate."
        case .noEstimate:        return "No estimate available for this address."
        case .network(let m):    return m
        }
    }
}

/// A source of property valuations. One small async method per provider, matching
/// the shape of the other RightmoveKit clients (`EPCClient`, `SoldHistoryClient`).
/// New providers are a new conformer, not a change to existing call sites.
public protocol ValuationProvider: Sendable {
    /// Short label shown in the UI and used as the result's identity.
    var source: String { get }
    /// Produce an estimate, or throw a `ValuationError`.
    func estimate(for query: ValuationQuery) async throws -> Valuation
}

/// Pure, network-free helpers for turning a single-line address into the
/// structured fields valuation APIs expect.
public enum ValuationAddress {

    /// Sub-building / flat designators that are never a street on their own.
    private static let unitWords = [
        "flat", "apartment", "apt", "unit", "room", "studio", "maisonette", "penthouse",
    ]

    /// Pull a flat / sub-building designator from a single-line address, e.g.
    /// "Flat C", "Apartment 5B", "Studio". Returns nil for a whole house.
    ///
    /// Examples:
    /// - "Flat C, 52 Dukes Avenue, N10 2PU" → "Flat C"
    /// - "Apartment 5B, 12 Acre Lane"       → "Apartment 5B"
    /// - "Flat C 52 Dukes Avenue"           → "Flat C"  (inline)
    /// - "Penthouse, 1 High Road"           → "Penthouse"
    /// - "52 Dukes Avenue, London"          → nil
    public static func subBuildingName(from address: String?) -> String? {
        guard let raw = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let segments = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let unitAlt = unitWords.joined(separator: "|")

        // 1. A segment that is *only* a unit designator: "Flat C", "Apartment 5B",
        //    "Studio". The id token is optional (a bare "Penthouse" is valid).
        let pureUnit = "^(\(unitAlt))(\\s+[0-9a-z]+)?$"
        for seg in segments {
            if seg.range(of: pureUnit, options: [.regularExpression, .caseInsensitive]) != nil {
                return seg
            }
        }
        // 2. An inline leading unit prefix on a longer segment, e.g.
        //    "Flat C 52 Dukes Avenue" → "Flat C".
        let inlineUnit = "^(\(unitAlt))\\s+[0-9a-z]+\\b"
        for seg in segments {
            if let r = seg.range(of: inlineUnit,
                                 options: [.regularExpression, .caseInsensitive]) {
                return String(seg[r]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Pull the leading building number from a single-line address.
    ///
    /// Examples:
    /// - "15, Felmersham Close, SW4 7EU" → "15"
    /// - "12 Acre Lane, London"          → "12"
    /// - "Flat 2, 12 Acre Lane"          → "12"   (first standalone number)
    /// - "12A Acre Lane"                 → "12A"
    /// - "Acre Lane, London"             → nil
    public static func buildingNumber(from address: String?) -> String? {
        guard let raw = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let segments = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Prefer a standalone number token ("15", "12A") — the typical EPC /
        // Land-Registry address shape "<number>, <street>, …".
        for seg in segments {
            if seg.range(of: #"^\d+[A-Za-z]?$"#, options: .regularExpression) != nil {
                return seg.uppercased()
            }
        }
        // Otherwise take a number that leads a segment ("12 Acre Lane"), skipping
        // pure unit prefixes like "Flat 2".
        for seg in segments {
            let lower = seg.lowercased()
            if lower.hasPrefix("flat") || lower.hasPrefix("apartment")
                || lower.hasPrefix("apt") || lower.hasPrefix("unit")
                || lower.hasPrefix("room") || lower.hasPrefix("studio") {
                continue
            }
            if let r = seg.range(of: #"^\d+[A-Za-z]?(?=\s)"#, options: .regularExpression) {
                return String(seg[r]).uppercased()
            }
        }
        return nil
    }
}
