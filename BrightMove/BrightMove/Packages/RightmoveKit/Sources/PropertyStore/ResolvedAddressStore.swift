import Foundation
import SwiftData

/// Thin persistence service for `ResolvedAddress`, mirroring `TrackingStore`'s
/// shape. Pure SwiftData; resolving/geocoding lives in the app layer.
@MainActor
public final class ResolvedAddressStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// In-memory store for previews and tests.
    public static func inMemory() throws -> ResolvedAddressStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ResolvedAddress.self, configurations: config)
        return ResolvedAddressStore(context: ModelContext(container))
    }

    public func lookup(propertyID: Int) -> ResolvedAddress? {
        let descriptor = FetchDescriptor<ResolvedAddress>(
            predicate: #Predicate { $0.propertyID == propertyID })
        return try? context.fetch(descriptor).first
    }

    /// Insert or replace the cached resolution for a property. Returns the
    /// stored model. A previously *confirmed* address is preserved across a
    /// re-resolve: the candidate list refreshes but the user's choice stands.
    @discardableResult
    public func upsert(propertyID: Int,
                       candidates: [StoredCandidate],
                       method: String = "epc") -> ResolvedAddress {
        if let existing = lookup(propertyID: propertyID) {
            existing.method = method
            existing.resolvedAt = Date()
            existing.setCandidates(candidates)
            try? context.save()
            return existing
        }
        let model = ResolvedAddress(propertyID: propertyID, candidates: candidates, method: method)
        context.insert(model)
        try? context.save()
        return model
    }

    /// Commit a user-chosen candidate as the confirmed address.
    public func confirm(propertyID: Int, choosing candidate: StoredCandidate) {
        guard let model = lookup(propertyID: propertyID) else { return }
        model.confirm(candidate)
        try? context.save()
    }

    public func delete(propertyID: Int) {
        guard let model = lookup(propertyID: propertyID) else { return }
        context.delete(model)
        try? context.save()
    }
}
