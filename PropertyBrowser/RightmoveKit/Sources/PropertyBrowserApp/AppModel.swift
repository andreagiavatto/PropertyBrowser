import Foundation
import SwiftData
import Observation
import RightmoveKit
import PropertyStore

/// App-wide state: owns the network client, the current search, and the
/// refresh machinery (manual + a daily background schedule).
@MainActor
@Observable
final class AppModel {
    let client = RightmoveClient()

    // Search
    var searchText = ""
    var results: [SearchProperty] = []
    var resultCount: String?
    var isSearching = false
    var searchError: String?

    // Refresh
    var isRefreshing = false
    var lastRefreshSummary: String?

    private var context: ModelContext?
    private var scheduler: NSBackgroundActivityScheduler?

    /// Wire up the SwiftData context once the view hierarchy exists, and start
    /// the daily background refresh.
    func attach(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        scheduleDailyRefresh()
    }

    func runSearch() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let search = RightmoveSearchURL(string: trimmed) else {
            searchError = "That doesn't look like a Rightmove search URL."
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            let page = try await client.fetchSearchResults(search)
            results = page.properties
            resultCount = page.resultCount?.description
        } catch {
            results = []
            resultCount = nil
            searchError = "\(error)"
        }
    }

    @discardableResult
    func refreshAll() async -> String {
        guard let context else { return "Not ready." }
        isRefreshing = true
        defer { isRefreshing = false }
        let store = TrackingStore(context: context)
        let summary = await RefreshService(client: client).refreshAll(store: store)
        lastRefreshSummary = summary
        return summary
    }

    private func scheduleDailyRefresh() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.propertybrowser.dailyRefresh")
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60      // daily
        scheduler.tolerance = 60 * 60          // ±1h
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.refreshAll()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }
}
