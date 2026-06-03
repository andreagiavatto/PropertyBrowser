import Foundation
import RightmoveKit
import PropertyStore

/// Re-fetches every pinned property's detail page and folds the result into the
/// store, recording price/status/delisting changes. A 404/410 (or a page that
/// reports archived) is treated as a delisting.
@MainActor
struct RefreshService {
    let client: RightmoveClient

    func refreshAll(store: TrackingStore) async -> String {
        let pins = store.allPins()
        guard !pins.isEmpty else { return "No pinned properties to refresh." }

        var checked = 0
        var changes = 0
        var errors = 0
        let now = Date()

        for pin in pins {
            let id = pin.propertyID
            do {
                let detail = try await client.fetchPropertyDetail(id: id)
                if let snapshot = TrackedSnapshot(detail: detail, at: now) {
                    changes += store.apply(snapshot).count
                    checked += 1
                } else {
                    store.markChecked(id: id, at: now)
                }
            } catch let error as RightmoveClientError {
                if case .httpError(let code) = error, code == 404 || code == 410 {
                    // Listing gone → record a delisting against the last known data.
                    let delisted = TrackedSnapshot(
                        propertyID: id,
                        priceAmount: pin.currentPriceAmount,
                        priceDisplay: pin.currentPriceDisplay,
                        state: .delisted,
                        capturedAt: now,
                        displayAddress: pin.displayAddress,
                        bedrooms: pin.bedrooms
                    )
                    changes += store.apply(delisted).count
                    checked += 1
                } else {
                    store.markChecked(id: id, at: now)
                    errors += 1
                }
            } catch {
                store.markChecked(id: id, at: now)
                errors += 1
            }
        }

        var summary = "Checked \(checked) of \(pins.count); \(changes) change\(changes == 1 ? "" : "s")"
        if errors > 0 { summary += "; \(errors) error\(errors == 1 ? "" : "s")" }
        return summary
    }
}
