import Combine
import Foundation
import RightmoveKit

/// One provider's answer for the detail view to render. Keeps successes and
/// failures side-by-side so multiple providers can stack as rows, each showing
/// its own figure or its own "unavailable" line.
enum ValuationOutcome: Identifiable {
    case estimate(Valuation)
    case failure(source: String, error: ValuationError)

    var source: String {
        switch self {
        case .estimate(let v):       return v.source
        case .failure(let s, _):     return s
        }
    }
    var id: String { source }
}

/// Fans a `ValuationQuery` out to every configured `ValuationProvider` and
/// publishes the per-provider outcomes for SwiftUI.
///
/// Deliberately ephemeral — results live only for the lifetime of the view and
/// are refetched on reopen, so a stale number is never shown. Bridges the pure
/// RightmoveKit providers to `@Published` state, the same role
/// `StationProximityService` plays for transit.
@MainActor
final class ValuationService: ObservableObject {
    @Published private(set) var outcomes: [ValuationOutcome] = []
    @Published private(set) var isLoading = false

    private let providers: [ValuationProvider]

    /// L&C is the only provider today; add conformers here to stack more.
    init(providers: [ValuationProvider] = [LandCValuationClient()]) {
        self.providers = providers
    }

    var hasResults: Bool { !outcomes.isEmpty || isLoading }

    /// Query every provider. Sequential is fine while there's one provider;
    /// switch to a task group if the list grows. Each provider's thrown
    /// `ValuationError` becomes a `.failure` row rather than aborting the rest.
    func load(query: ValuationQuery) async {
        isLoading = true
        defer { isLoading = false }
        outcomes = []

        var collected: [ValuationOutcome] = []
        for provider in providers {
            do {
                let valuation = try await provider.estimate(for: query)
                collected.append(.estimate(valuation))
            } catch let error as ValuationError {
                collected.append(.failure(source: provider.source, error: error))
            } catch {
                collected.append(.failure(source: provider.source,
                                          error: .network("Couldn't reach \(provider.source).")))
            }
        }
        outcomes = collected
    }

    func reset() {
        outcomes = []
        isLoading = false
    }
}
