import Foundation

/// Identifies the exact civic address of a listing by matching its Land-Registry
/// sold-price history (from Rightmove's `soldProperty/transactionHistory`) against
/// the Price Paid records for its postcode (from `LandRegistryClient`).
///
/// A property's sale history is a near-unique fingerprint within a postcode: the
/// address whose Price Paid records reproduce the listing's (year, price) sales is
/// almost certainly the listing. Matching several sales makes it conclusive.
public enum PricePaidMatcher {

    /// One candidate address with how strongly its Price Paid history matches the
    /// listing's sold history.
    public struct Identification: Equatable, Sendable {
        public let paon: String?
        public let saon: String?
        public let street: String?
        public let postcode: String?
        /// How many of the listing's sold transactions this address reproduces.
        public let matchedTransactions: Int
        public let lastSoldPrice: Int?
        public let lastSoldYear: Int?

        /// A single-line civic address, e.g. "Flat 2, 5" or "10".
        public var civicLabel: String {
            [saon, paon].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// Rank the postcode's addresses by how many of the listing's sold
    /// transactions they reproduce (a sale matches on identical year *and* price).
    /// Addresses with zero matches are omitted.
    public static func identify(
        soldHistory: [SoldTransaction],
        transactions: [PricePaidRecord]
    ) -> [Identification] {
        // Group Price Paid records by dwelling (saon + paon + street).
        var groups: [String: [PricePaidRecord]] = [:]
        for record in transactions {
            let key = dwellingKey(saon: record.saon, paon: record.paon, street: record.street)
            groups[key, default: []].append(record)
        }

        // The listing's (year, price) sales to match against.
        let wanted: [(year: Int, price: Int)] = soldHistory.compactMap {
            guard let y = $0.year, let p = $0.price else { return nil }
            return (y, p)
        }

        var ids: [Identification] = []
        for records in groups.values {
            let matched = wanted.filter { sale in
                records.contains { $0.year == sale.year && $0.price == sale.price }
            }.count
            guard matched > 0 else { continue }

            let latest = records.max { $0.date < $1.date }
            ids.append(Identification(
                paon: latest?.paon,
                saon: latest?.saon,
                street: latest?.street,
                postcode: latest?.postcode,
                matchedTransactions: matched,
                lastSoldPrice: latest?.price,
                lastSoldYear: latest?.year))
        }

        // Most matches first; break ties by most recent sale.
        return ids.sorted {
            if $0.matchedTransactions != $1.matchedTransactions {
                return $0.matchedTransactions > $1.matchedTransactions
            }
            return ($0.lastSoldYear ?? 0) > ($1.lastSoldYear ?? 0)
        }
    }

    /// The confident single match, or nil when the result is ambiguous.
    ///
    /// Confident when the top address matches ≥2 sales and no other address ties
    /// it, or when exactly one address matches at all. Otherwise the caller should
    /// present the ranked `identify(...)` list for manual choice.
    public static func bestMatch(
        soldHistory: [SoldTransaction],
        transactions: [PricePaidRecord]
    ) -> Identification? {
        let ranked = identify(soldHistory: soldHistory, transactions: transactions)
        guard let top = ranked.first else { return nil }

        let withMatches = ranked.filter { $0.matchedTransactions > 0 }
        if withMatches.count == 1 { return top }

        let tiedAtTop = ranked.filter { $0.matchedTransactions == top.matchedTransactions }
        if top.matchedTransactions >= 2 && tiedAtTop.count == 1 { return top }

        return nil
    }

    /// Normalised dwelling key: lowercase alphanumerics of saon + paon + street.
    private static func dwellingKey(saon: String?, paon: String?, street: String?) -> String {
        [saon, paon, street]
            .compactMap { $0 }
            .map { str -> String in
                let lower = str.lowercased()
                let filteredScalars = lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                return String(filteredScalars)
            }
            .joined(separator: "|")
    }
}
