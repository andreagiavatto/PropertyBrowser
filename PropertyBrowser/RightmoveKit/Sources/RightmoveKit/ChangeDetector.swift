import Foundation

/// A single change detected between two snapshots of a property.
public enum PropertyChange: Equatable, Sendable {
    /// The first time we ever captured this property.
    case firstSeen(TrackedSnapshot)
    /// Asking price changed.
    case priceChanged(fromAmount: Int?, toAmount: Int?, fromDisplay: String?, toDisplay: String?)
    /// Market state changed (covers available ↔ underOffer ↔ soldSTC ↔ delisted,
    /// including relisting when `from == .delisted`).
    case stateChanged(from: ListingState, to: ListingState)

    /// True if this is a price drop (useful for the changes feed / filtering).
    public var isPriceReduction: Bool {
        if case let .priceChanged(from, to, _, _) = self, let f = from, let t = to { return t < f }
        return false
    }
}

/// Pure, dependency-free comparison of two snapshots into a list of changes.
/// This is the tracking logic the whole app is built around, kept testable in
/// isolation from SwiftData and networking.
public enum ChangeDetector {

    /// Diff a freshly fetched `current` snapshot against the last known one.
    /// Passing `previous == nil` yields a single `.firstSeen`.
    public static func diff(previous: TrackedSnapshot?, current: TrackedSnapshot) -> [PropertyChange] {
        guard let previous else {
            return [.firstSeen(current)]
        }

        var changes: [PropertyChange] = []

        if previous.priceAmount != current.priceAmount {
            changes.append(.priceChanged(
                fromAmount: previous.priceAmount,
                toAmount: current.priceAmount,
                fromDisplay: previous.priceDisplay,
                toDisplay: current.priceDisplay
            ))
        }

        if previous.state != current.state {
            changes.append(.stateChanged(from: previous.state, to: current.state))
        }

        return changes
    }
}
