import Foundation

/// The market state of a listing, derived from the raw Rightmove signals.
///
/// Detail pages expose Sold STC / Under Offer in `propertyData.tags`
/// (e.g. "SOLD_STC", "UNDER_OFFER") and full removal in `status`
/// (`archived == true` / `published == false`). Search-results pages expose it
/// in `displayStatus` and/or a per-property `tags` array. This enum collapses
/// all of those into one value the rest of the app can track.
public enum ListingState: String, Equatable {
    case available
    case underOffer
    case soldSTC
    case delisted
    /// A status string/tag we don't recognise yet — surfaced rather than hidden
    /// so it shows up during validation instead of being silently mis-mapped.
    case unknown

    /// Derive state from the signals available on either page type.
    /// - Parameters:
    ///   - archived: `status.archived` (detail page); nil if unknown.
    ///   - published: `status.published` (detail page); nil if unknown.
    ///   - tags: per-property tags (e.g. ["SOLD_STC"]).
    ///   - displayStatus: search-results `displayStatus` string.
    static func derive(archived: Bool?, published: Bool?, tags: [String]?, displayStatus: String?) -> ListingState {
        if archived == true || published == false { return .delisted }

        let upperTags = Set((tags ?? []).map { $0.uppercased() })
        if upperTags.contains("SOLD_STC") || upperTags.contains("SOLD_SUBJECT_TO_CONTRACT") { return .soldSTC }
        if upperTags.contains("UNDER_OFFER") { return .underOffer }

        if let raw = displayStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let l = raw.lowercased()
            if l.contains("sold") { return .soldSTC }
            if l.contains("under offer") || l.contains("under-offer") { return .underOffer }
            return .unknown
        }

        return .available
    }
}
