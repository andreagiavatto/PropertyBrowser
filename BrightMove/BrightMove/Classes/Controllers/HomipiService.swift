import Combine
import Foundation
import RightmoveKit

/// Loads a property's Homipi profile for the detail-view section, bridging the
/// pure `HomipiClient` to `@Published` state for SwiftUI.
///
/// Deliberately ephemeral — like `ValuationService`, the report lives only for
/// the view's lifetime and is refetched on reopen, so stale figures are never
/// shown. The report is now parsed straight from Homipi's postcode listing (no
/// detail-page fetch), so it carries the listing-level facts — value change,
/// last sold, type/tenure — and the price-estimate row itself is still handled
/// separately by `HomipiValuationProvider` in `ValuationService`. The two fetch
/// the postcode page independently — an accepted double fetch in exchange for
/// keeping the valuation stack and this section fully decoupled.
@MainActor
final class HomipiService: ObservableObject {
    @Published private(set) var report: HomipiReport?
    @Published private(set) var isLoading = false
    /// Set when a load finished without a usable report, so the section can show
    /// a quiet, labelled unavailable line rather than vanishing mid-fetch.
    @Published private(set) var failed = false

    private let client: HomipiClient
    /// The address+postcode of the in-flight / last load, so repeat triggers for
    /// the same property don't refetch.
    private var loadedKey: String?

    init(client: HomipiClient = HomipiClient()) {
        self.client = client
    }

    var hasContent: Bool { report != nil || isLoading }

    /// Fetch the Homipi report for a confirmed address. No-ops if the same
    /// address is already loaded or loading.
    func load(resolvedAddress: String?, postcode: String?) async {
        guard let address = resolvedAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else { return }
        let key = "\(address)|\(postcode ?? "")"
        guard key != loadedKey else { return }
        loadedKey = key

        isLoading = true
        failed = false
        defer { isLoading = false }

        do {
            report = try await client.fetchReport(resolvedAddress: address, postcode: postcode)
        } catch {
            print(error)
            report = nil
            failed = true
            loadedKey = nil   // allow a retry on the next trigger
        }
    }

    func reset() {
        report = nil
        isLoading = false
        failed = false
        loadedKey = nil
    }
}
