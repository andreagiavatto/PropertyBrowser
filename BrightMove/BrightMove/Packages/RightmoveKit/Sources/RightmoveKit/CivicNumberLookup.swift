import Foundation

/// Ties the two halves of the civic-number cross-check together: fetch the
/// listing's Land-Registry sold history (via Rightmove) and the postcode's Price
/// Paid records (via Land Registry), then match them to pin the exact address.
///
/// Intended to run *after* EPC matching has produced a confident street + postcode
/// and the user has selected that address. The `deliveryPointId` / `encId` come
/// from the Rightmove property page model.
public enum CivicNumberLookup {

    public struct Result: Sendable {
        /// The confident single address, or nil when ambiguous.
        public let best: PricePaidMatcher.Identification?
        /// All postcode addresses that reproduce at least one of the listing's
        /// sales, ranked — for manual choice when `best` is nil.
        public let ranked: [PricePaidMatcher.Identification]
        /// The listing's sold history, surfaced for display alongside the match.
        public let soldHistory: SoldPropertyHistory
    }

    /// Fetch sold history + Price Paid data and identify the civic address.
    /// - Parameters:
    ///   - deliveryPointId/encId: from the Rightmove page model.
    ///   - postcode: the confirmed postcode from EPC matching.
    public static func identify(
        deliveryPointId: String,
        encId: String,
        propertyID: Int? = nil,
        postcode: String,
        soldHistoryClient: SoldHistoryClient = SoldHistoryClient(),
        landRegistry: LandRegistryClient = LandRegistryClient()
    ) async throws -> Result {
        async let historyTask = soldHistoryClient.history(
            deliveryPointId: deliveryPointId, encId: encId, propertyID: propertyID)
        async let recordsTask = landRegistry.transactions(postcode: postcode)
        let (history, records) = try await (historyTask, recordsTask)

        let txns = history.soldPropertyTransactions
        return Result(
            best: PricePaidMatcher.bestMatch(soldHistory: txns, transactions: records),
            ranked: PricePaidMatcher.identify(soldHistory: txns, transactions: records),
            soldHistory: history)
    }
}
