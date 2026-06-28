import Foundation
import SwiftData
import RightmoveKit

/// The persistence + tracking service: pins properties and turns each fresh
/// snapshot into recorded history. Pure SwiftData; networking lives elsewhere.
@MainActor
public final class TrackingStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Convenience: an in-memory store, handy for previews and tests.
    public static func inMemory() throws -> TrackingStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: PinnedProperty.self, PropertyEvent.self, ResolvedAddress.self,
            ViewedProperty.self,
            configurations: config)
        return TrackingStore(context: ModelContext(container))
    }

    public static var schema: [any PersistentModel.Type] {
        [PinnedProperty.self, PropertyEvent.self, ResolvedAddress.self, ViewedProperty.self]
    }

    // MARK: Queries

    public func pinnedProperty(id: Int) -> PinnedProperty? {
        let descriptor = FetchDescriptor<PinnedProperty>(predicate: #Predicate { $0.propertyID == id })
        return try? context.fetch(descriptor).first
    }

    public func isPinned(id: Int) -> Bool {
        pinnedProperty(id: id) != nil
    }

    public func allPins() -> [PinnedProperty] {
        let descriptor = FetchDescriptor<PinnedProperty>(sortBy: [SortDescriptor(\.pinnedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    public func viewedProperty(id: Int) -> ViewedProperty? {
        let descriptor = FetchDescriptor<ViewedProperty>(predicate: #Predicate { $0.propertyID == id })
        return try? context.fetch(descriptor).first
    }

    public func isViewed(id: Int) -> Bool {
        viewedProperty(id: id) != nil
    }

    public func allViewed() -> [ViewedProperty] {
        let descriptor = FetchDescriptor<ViewedProperty>(sortBy: [SortDescriptor(\.viewedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All events across all pins, newest first — the global Changes feed.
    public func recentChanges(limit: Int = 200) -> [PropertyEvent] {
        var descriptor = FetchDescriptor<PropertyEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Mutations

    /// Pin a property from a snapshot, recording a `firstSeen` event. Returns the
    /// existing pin unchanged if it was already pinned.
    @discardableResult
    public func pin(_ snapshot: TrackedSnapshot, sourceSearchURL: String? = nil) -> PinnedProperty {
        if let existing = pinnedProperty(id: snapshot.propertyID) { return existing }

        let pin = PinnedProperty(snapshot: snapshot, sourceSearchURL: sourceSearchURL)
        context.insert(pin)

        let event = PropertyEvent(
            kind: .firstSeen,
            date: snapshot.capturedAt,
            toAmount: snapshot.priceAmount,
            toDisplay: snapshot.priceDisplay,
            toState: snapshot.state
        )
        event.property = pin
        context.insert(event)

        try? context.save()
        return pin
    }

    /// Record that the user opened a property's detail view. Idempotent: inserts
    /// a `ViewedProperty` the first time, otherwise just bumps `viewedAt`. Safe to
    /// call repeatedly (e.g. on every `onAppear`).
    public func markViewed(id: Int, at date: Date = Date()) {
        if let existing = viewedProperty(id: id) {
            existing.viewedAt = date
        } else {
            context.insert(ViewedProperty(propertyID: id, viewedAt: date))
        }
        try? context.save()
    }

    public func unpin(id: Int) {
        guard let pin = pinnedProperty(id: id) else { return }
        context.delete(pin)   // cascade removes its events
        try? context.save()
    }

    /// Apply a freshly fetched snapshot to an existing pin: diff against the last
    /// known state, append events for any changes, and update the pin's current
    /// fields. Returns the events that were recorded (empty if nothing changed).
    /// No-op (returns []) if the property isn't pinned.
    @discardableResult
    public func apply(_ snapshot: TrackedSnapshot) -> [PropertyEvent] {
        guard let pin = pinnedProperty(id: snapshot.propertyID) else { return [] }

        let changes = ChangeDetector.diff(previous: pin.currentSnapshot, current: snapshot)
        var recorded: [PropertyEvent] = []

        for change in changes {
            guard let event = Self.makeEvent(change, at: snapshot.capturedAt) else { continue }
            event.property = pin
            context.insert(event)
            recorded.append(event)
        }

        // Update current state regardless of whether events were produced.
        pin.currentPriceAmount = snapshot.priceAmount
        pin.currentPriceDisplay = snapshot.priceDisplay
        pin.currentStateRaw = snapshot.state.rawValue
        pin.lastSeenAt = snapshot.capturedAt
        pin.lastCheckedAt = snapshot.capturedAt
        if let addr = snapshot.displayAddress { pin.displayAddress = addr }
        if let beds = snapshot.bedrooms { pin.bedrooms = beds }
        if let baths = snapshot.bathrooms { pin.bathrooms = baths }
        if let subtype = snapshot.propertySubType { pin.propertySubType = subtype }
        if let thumb = snapshot.thumbnailURLString { pin.thumbnailURLString = thumb }
        pin.isPriceReduced = snapshot.isPriceReduced
        if let added = snapshot.addedOrReduced { pin.addedOrReduced = added }

        try? context.save()
        return recorded
    }

    /// Record that a refresh ran but couldn't reach the property (so we touch
    /// `lastCheckedAt` without claiming it was seen). Used when a fetch errors
    /// but we don't yet have a delisted signal.
    public func markChecked(id: Int, at date: Date = Date()) {
        guard let pin = pinnedProperty(id: id) else { return }
        pin.lastCheckedAt = date
        try? context.save()
    }

    // MARK: Mapping

    private static func makeEvent(_ change: PropertyChange, at date: Date) -> PropertyEvent? {
        switch change {
        case .firstSeen(let snap):
            return PropertyEvent(
                kind: .firstSeen, date: date,
                toAmount: snap.priceAmount, toDisplay: snap.priceDisplay, toState: snap.state
            )
        case let .priceChanged(fromAmount, toAmount, fromDisplay, toDisplay):
            return PropertyEvent(
                kind: .priceChange, date: date,
                fromAmount: fromAmount, toAmount: toAmount,
                fromDisplay: fromDisplay, toDisplay: toDisplay
            )
        case let .stateChanged(from, to):
            return PropertyEvent(
                kind: .statusChange, date: date,
                fromState: from, toState: to
            )
        }
    }
}
