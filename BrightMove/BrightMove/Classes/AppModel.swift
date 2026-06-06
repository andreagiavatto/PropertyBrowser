import Foundation
import SwiftData
import Observation
import RightmoveKit
import PropertyStore

/// App-wide state: owns the network client, the structured search form, and the
/// refresh machinery (manual + a daily background schedule).
@MainActor
@Observable
final class AppModel {
    let client = RightmoveClient()

    // MARK: Search form

    /// The structured criteria the form edits. Bind directly to its fields.
    var criteria = RightmoveSearchCriteria()

    /// Free text in the area field, used to drive the typeahead.
    var locationQuery = ""
    var locationSuggestions: [LocationSuggestion] = []
    var isLookingUp = false
    var lookupError: String?

    /// Min/max price as edited text (digits only when committed to `criteria`).
    var minPriceText = ""
    var maxPriceText = ""

    // MARK: Results

    var results: [SearchProperty] = []
    var resultCount: String?
    var isSearching = false
    var searchError: String?

    /// True while a *subsequent* page is being appended (vs. `isSearching`,
    /// which covers a fresh first-page search).
    var isLoadingMore = false

    /// The URL string of the last run search, stored on pins as their source.
    var lastSearchURLString = ""

    // MARK: Pagination

    /// Rightmove serves results in pages of this size; `index` steps by it.
    private static let perPage = 24

    /// The search currently being paged through (set by `runSearch`).
    private var currentSearch: RightmoveSearchURL?
    /// `index` of the most recently loaded page (0, 24, 48, …).
    private var loadedIndex = 0
    /// Total number of pages available, once a page has reported it.
    private var totalPages: Int?

    /// Whether another page can be fetched: we have an active search, aren't
    /// already loading, and haven't reached the last known page.
    var canLoadMore: Bool {
        guard !isSearching, !isLoadingMore, currentSearch != nil else { return false }
        guard let totalPages else { return false }
        let pagesLoaded = (loadedIndex / Self.perPage) + 1
        return pagesLoaded < totalPages
    }

    // MARK: Refresh

    var isRefreshing = false
    var lastRefreshSummary: String?

    private var context: ModelContext?
    private var scheduler: NSBackgroundActivityScheduler?
    private var lookupTask: Task<Void, Never>?

    private static let persistenceKey = "lastSearchCriteria"

    init() {
        restoreCriteria()
    }

    /// True once a location is selected and we're not mid-request.
    var canSearch: Bool { criteria.hasLocation && !isSearching }

    /// Wire up the SwiftData context once the view hierarchy exists, and start
    /// the daily background refresh.
    func attach(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        scheduleDailyRefresh()
    }

    // MARK: Typeahead

    /// Debounced location lookup driven by the area field. Cancels any in-flight
    /// lookup and fetches ~300ms after the user stops typing.
    func locationQueryChanged() {
        lookupTask?.cancel()

        // Editing the text after a selection invalidates that selection.
        if locationQuery != criteria.displayName {
            criteria.locationIdentifier = ""
        }

        let query = locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            locationSuggestions = []
            lookupError = nil
            isLookingUp = false
            return
        }

        lookupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.performLookup(query: query)
        }
    }

    private func performLookup(query: String) async {
        isLookingUp = true
        lookupError = nil
        defer { isLookingUp = false }
        do {
            let matches = try await client.fetchLocationSuggestions(query: query)
            guard !Task.isCancelled else { return }
            locationSuggestions = matches
            lookupError = matches.isEmpty ? "No places found." : nil
        } catch {
            guard !Task.isCancelled else { return }
            locationSuggestions = []
            lookupError = "Couldn't look up locations — try again."
        }
    }

    /// Hides the typeahead dropdown without altering the current selection.
    /// Used when the area field loses focus or the user presses Escape.
    func dismissSuggestions() {
        lookupTask?.cancel()
        locationSuggestions = []
        lookupError = nil
        isLookingUp = false
    }

    /// Records the user's pick from the dropdown.
    func selectLocation(_ suggestion: LocationSuggestion) {
        criteria.locationIdentifier = suggestion.locationIdentifier
        criteria.displayName = suggestion.displayName
        locationQuery = suggestion.displayName
        locationSuggestions = []
        lookupError = nil
        lookupTask?.cancel()
    }

    // MARK: Search

    func runSearch() async {
        // Commit price text into the criteria (digits only).
        criteria.minPrice = Self.digits(minPriceText)
        criteria.maxPrice = Self.digits(maxPriceText)

        guard let search = RightmoveSearchURL(criteria: criteria) else {
            searchError = "Choose an area to search."
            return
        }
        guard let url = search.firstPageURL() else {
            searchError = "Couldn't build a search URL."
            return
        }

        isSearching = true
        searchError = nil
        // Reset pagination for a fresh search.
        currentSearch = search
        loadedIndex = 0
        totalPages = nil
        defer { isSearching = false }
        do {
            let page = try await client.fetchSearchResults(search, index: 0)
            results = page.properties
            resultCount = page.resultCount?.description
            totalPages = page.pagination?.total?.int
            lastSearchURLString = url.absoluteString
            persistCriteria()
        } catch {
            results = []
            resultCount = nil
            currentSearch = nil
            searchError = "\(error)"
        }
    }

    /// Fetches the next page and appends its results to the current list.
    /// No-op when there's nothing more to load or a load is already in flight.
    func loadNextPage() async {
        guard canLoadMore, let search = currentSearch else { return }
        let nextIndex = loadedIndex + Self.perPage

        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.fetchSearchResults(search, index: nextIndex)
            // Guard against rare cross-page duplicates so SwiftUI's ForEach keys
            // stay unique.
            let existing = Set(results.map(\.listingKey))
            results.append(contentsOf: page.properties.filter { !existing.contains($0.listingKey) })
            loadedIndex = nextIndex
            if let total = page.pagination?.total?.int { totalPages = total }
            if let count = page.resultCount?.description { resultCount = count }
        } catch {
            searchError = "\(error)"
        }
    }

    // MARK: Persistence

    private func persistCriteria() {
        guard let data = try? JSONEncoder().encode(criteria) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    private func restoreCriteria() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
              let saved = try? JSONDecoder().decode(RightmoveSearchCriteria.self, from: data)
        else { return }
        criteria = saved
        locationQuery = saved.displayName
        minPriceText = saved.minPrice ?? ""
        maxPriceText = saved.maxPrice ?? ""
    }

    private static func digits(_ s: String) -> String? {
        let d = s.filter(\.isNumber)
        return d.isEmpty ? nil : d
    }

    // MARK: Tracking refresh

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
