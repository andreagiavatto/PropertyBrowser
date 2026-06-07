# Search Map View — Implementation Plan

A List/Map toggle inside `SearchView` that renders the existing search results on an
`MKMapView` with price-labelled, clustered annotations. The map is a pure *renderer* of
the current location+radius search — no new search semantics.

This plan is grounded in the current code: `SearchView` renders `model.results` in a
`LazyVGrid`; `AppModel` owns `results: [SearchProperty]`, `runSearch()`, `loadNextPage()`,
and the pagination counters (`loadedIndex`, `totalPages`, `canLoadMore`, `perPage = 24`);
each `SearchProperty` carries `location: GeoLocation?` with optional `lat`/`lng`. MapKit is
already a dependency (used in `PropertyDetailView` and `StationProximityService`). Target is
macOS 15.

---

## Agreed design (reference)

1. List/Map segmented toggle inside `SearchView`, on the results-count row; map swaps in for the grid region, form stays pinned.
2. Entering map streams remaining pages via `loadNextPage()`, **capped at 10 pages (~240)** with a ~200–300ms inter-request delay; show a "showing first N — narrow your search" note when capped.
3. `MKMapView` via `NSViewRepresentable`; price-capsule annotations with native `clusteringIdentifier` clustering; pinned properties visually distinguished.
4. Pin tap → popover callout with a compact card (photo/price/beds/address + pin toggle) and a "View details" push to `PropertyDetailView`.
5. Cluster tap → zoom-to-decluster.
6. Camera fits to loaded pins on fresh-result arrival, with a user-moved-the-map guard within a result set; fall back to search-location center if no mappable results.
7. No-coords results dropped from the map, count disclosed ("N not shown on map").
8. New search in map mode → stay in map, clear pins, re-fit on completion.
9. Pan-to-search → out of scope (pure renderer).
10. View-mode state session-only, stored in `AppModel` (survives section switches, not app restarts; no `@AppStorage`).
11. Load loop leans on existing `loadedIndex`/`canLoadMore`/cap; idempotent across toggles; gated to map mode so it pauses/resumes with the toggle.

---

## New files

### 1. `Classes/SubViews/PropertyMapView.swift` — `NSViewRepresentable`

The bridge from SwiftUI to `MKMapView`. Owns no model state itself; it's driven by inputs
and reports user actions back via closures.

```
struct PropertyMapView: NSViewRepresentable {
    let properties: [SearchProperty]          // only mappable ones (caller filters)
    let pinnedIDs: Set<Int>
    var fitToken: Int                          // bump to request a camera re-fit
    var fallbackCenter: CLLocationCoordinate2D? // search-location center, for empty case
    let onSelect: (Int) -> Void                // tapped "View details" → propertyID
    let onTogglePin: (Int) -> Void             // pin toggle from callout → propertyID

    func makeNSView(context:) -> MKMapView
    func updateNSView(_:context:)
    func makeCoordinator() -> Coordinator
}
```

`makeNSView`: create `MKMapView`, set `delegate = context.coordinator`,
register annotation + cluster view classes (`register(_:forAnnotationViewWithReuseIdentifier:)`),
and store a back-reference on the coordinator.

`updateNSView` (the heart of the diffing):
- Diff incoming `properties` against the annotations currently on the map by `propertyID`;
  add new, remove dropped. Don't blanket `removeAnnotations`/`addAnnotations` every update —
  that kills clustering animation and selection. Keep a `[Int: PropertyAnnotation]` map on
  the coordinator keyed by `propertyID`.
- If a property's pinned-state changed, update the existing annotation's `isPinned` and ask
  its view to refresh (or just update glyph tint in the view-for-annotation path).
- If `fitToken` changed since last seen, call `coordinator.fitToAnnotations(fallback:)`
  unless the user has manually moved the map for this result set (see guard below).

### 2. `Classes/SubViews/PropertyMapView+Coordinator.swift` — `MKMapViewDelegate`

```
final class Coordinator: NSObject, MKMapViewDelegate {
    var parent: PropertyMapView
    weak var mapView: MKMapView?
    var annotationsByID: [Int: PropertyAnnotation] = [:]
    var lastFitToken: Int = -1
    var userMovedMap = false      // set on user-initiated region change; reset on re-fit
    ...
}
```

Delegate methods:
- `mapView(_:viewFor:)` — dequeue/configure the price-capsule view for `PropertyAnnotation`;
  return the cluster view for `MKClusterAnnotation`. Set `clusteringIdentifier` on the member
  view so MapKit clusters them.
- `mapView(_:didSelect:)` —
  - `MKClusterAnnotation` → compute member bounding `MKMapRect`, `setVisibleMapRect(_:animated:)`
    to zoom-to-decluster (decision 5); deselect.
  - `PropertyAnnotation` → present the callout card (see callout note below).
- `mapView(_:regionDidChangeAnimated:)` — if the change was user-initiated (track via
  `mapViewDidChangeVisibleRegion` / a gesture flag, or compare against a programmatic-change
  flag we set around our own `setRegion`/`setVisibleMapRect` calls), set `userMovedMap = true`.
  This implements the "user-moved-the-map guard" (decision 6).
- `fitToAnnotations(fallback:)` — if there are annotations, `showAnnotations(_, animated:)`
  (or compute a padded `MKMapRect` union); else if `fallback` center exists, `setRegion`
  around it at a default span. Set a programmatic-change flag around the call so the
  region-change delegate doesn't mistake it for a user pan, then reset `userMovedMap = false`.

**Callout strategy:** the cleanest macOS approach is `MKAnnotationView.detailCalloutAccessoryView`
hosting an `NSHostingView` of a SwiftUI `MapCalloutCard`. Set `canShowCallout = true` on the
price-capsule view and assign the hosting view in `viewFor`/`didSelect`. The card's
"View details" button calls `parent.onSelect(id)`; its pin button calls `parent.onTogglePin(id)`.

### 3. `Classes/SubViews/PropertyAnnotation.swift` — annotation model + views

```
final class PropertyAnnotation: NSObject, MKAnnotation {
    let propertyID: Int
    let coordinate: CLLocationCoordinate2D
    let priceText: String          // short form, e.g. "£450k"
    var isPinned: Bool
    // plus whatever the callout card needs: thumbnail URL, beds, address, listingKey
}
```

- `PriceCapsuleAnnotationView: MKAnnotationView` — draws the rounded price capsule
  (an `NSHostingView` of a tiny SwiftUI capsule, or Core Graphics). Sets
  `clusteringIdentifier = "property"`, `canShowCallout = true`, `collisionMode = .circle`.
  Pinned → accent tint/badge (decision 3).
- `PropertyClusterAnnotationView: MKAnnotationView` (or subclass `MKMarkerAnnotationView`) —
  shows the member count. Also set a `clusteringIdentifier` so clusters re-cluster as you zoom.
- A `£k`/`£m` short-price formatter (e.g. 450000 → "£450k", 1250000 → "£1.25m"). Source price
  from `SearchProperty.price?.amount?.int`; fall back to `price?.primaryDisplay` truncated.

### 4. `Classes/SubViews/MapCalloutCard.swift` — SwiftUI callout content (decision 4)

Compact card: thumbnail (`propertyImages?.images?.first?.srcUrl`), price, beds/baths,
address, a pin toggle, and a "View details" button. Can reuse `PropertyCardData`-derived
fields, but keep it its own small view sized for a callout (the full `PropertyCard` is grid-sized).

---

## Changes to existing files

### `Classes/AppModel.swift`

Add view-mode state (decision 10 — lives here so it survives `RootView` rebuilding `SearchView`
on section switches, session-only, **not** `@AppStorage`):

```
enum SearchViewMode { case list, map }
var searchViewMode: SearchViewMode = .list
var fitToken = 0                    // bumped to request a map camera re-fit
private(set) var didCapMapLoad = false   // drives the "showing first N" note
```

Add the **capped streaming auto-load loop** (decisions 2, 11, 12):

```
private static let mapPageCap = 10          // ~240 results
private var mapLoadTask: Task<Void, Never>?

func enterMapMode() {
    searchViewMode = .map
    startMapAutoLoad()
}

func exitMapMode() {
    searchViewMode = .list
    mapLoadTask?.cancel()                    // pause; pagination state is preserved
}

private func startMapAutoLoad() {
    mapLoadTask?.cancel()
    mapLoadTask = Task { @MainActor in
        // Leans entirely on existing canLoadMore / loadedIndex (decision 11 = idempotent).
        while searchViewMode == .map,
              canLoadMore,
              (loadedIndex / Self.perPage) + 1 < Self.mapPageCap {
            await loadNextPage()
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 250_000_000)   // polite delay (decision 12)
        }
        didCapMapLoad = canLoadMore && (loadedIndex / Self.perPage) + 1 >= Self.mapPageCap
    }
}
```

In `runSearch()` (decision 8 — stay in map, re-fit on completion): after a successful fresh
search, if `searchViewMode == .map`, bump `fitToken` and call `startMapAutoLoad()` again.
`results` is already reset by the existing assignment `results = page.properties`, so pins
clear naturally. Reset `didCapMapLoad = false` at the start of a fresh search.

Note: the loop re-checks `searchViewMode == .map` each iteration, so switching to list mid-load
lets the in-flight `loadNextPage()` finish and then stops (decision 11). Re-entering map resumes
from the preserved `loadedIndex` and refetches nothing (idempotent).

### `Classes/SearchView.swift`

1. **Toggle on the results-count row** (decision 1):
   replace the `if let count = model.resultCount` block with an `HStack` containing the count
   text, a `Picker(selection:)` styled `.segmented` bound to a `searchViewMode` binding
   (get `model.searchViewMode`; set → `enterMapMode()` / `exitMapMode()`), and — when in map
   mode — the disclosure notes: "N not shown on map" (decision 7) and, if `model.didCapMapLoad`,
   "showing first 240 — narrow your search" (decision 2).

2. **Swap the content region** (decision 1, 10): wrap the existing `ScrollView { LazyVGrid … }`
   in `if model.searchViewMode == .list { …existing grid… } else { mapSection }`. The form,
   divider, and error/count chrome above are untouched.

3. **`mapSection`** computes the mappable split and renders `PropertyMapView`:

```
@ViewBuilder private var mapSection: some View {
    let mapped = model.results.filter { $0.location?.lat != nil && $0.location?.lng != nil }
    PropertyMapView(
        properties: mapped,
        pinnedIDs: pinnedIDs,
        fitToken: model.fitToken,
        fallbackCenter: searchCenterCoordinate,   // from criteria/last result, optional
        onSelect: { id in navPath… push(id) },     // see navigation note
        onTogglePin: { id in togglePinByID(id) }
    )
    .overlay { if mapped.isEmpty && !model.isSearching { ContentUnavailableView(…"No mappable results"…) } }
}
```

4. The unmapped count for decision 7 = `model.results.count - mapped.count`.

5. **Pin toggle by id**: the existing `togglePin(_ property:)` takes a `SearchProperty`; add a
   small `togglePinByID(_ id: Int)` that looks the property up in `model.results` (or refactor
   `togglePin` to accept an id) so the map callout can pin without holding the struct.

### Navigation (`onSelect` → `PropertyDetailView`)

`RootView` already has `.navigationDestination(for: Int.self)`. From a list card, navigation
happens via `NavigationLink(value: id)`. From the map callout there's no `NavigationLink`, so
either:
- (preferred) give `SearchView` a `@State private var path = NavigationPath` is **not** possible
  because the `NavigationStack` lives in `RootView`. Instead, lift a `NavigationPath` binding to
  `RootView` and pass it down, **or**
- expose a `@State` selected-id on `RootView`'s `NavigationStack(path:)` and have `onSelect`
  append to it via the environment model (add `var pendingDetailID: Int?` to `AppModel`, observe
  it in `RootView` to append to the path).

Recommended: convert `RootView`'s `NavigationStack` to `NavigationStack(path:)` backed by a
`@State NavigationPath`, store nothing extra in the model, and pass an `onSelect` closure (or a
`@Binding`) into `SearchView`. This keeps the list `NavigationLink(value:)` working (it appends
to the same path) and lets the map callout append programmatically.

---

## Build order

1. `AppModel`: add `searchViewMode`, `fitToken`, `didCapMapLoad`, the cap constant, and the
   auto-load loop + `enter/exitMapMode`; wire `runSearch()` re-fit. *(Compiles, no UI yet.)*
2. `PropertyAnnotation.swift`: annotation model, price-capsule view, cluster view, price formatter.
3. `PropertyMapView.swift` + Coordinator: representable, annotation diffing, fit logic,
   cluster zoom-to-decluster, callout hosting.
4. `MapCalloutCard.swift`: callout content with pin toggle + view-details.
5. `SearchView.swift`: toggle row, list/map swap, mappable split + disclosure notes, pin-by-id.
6. Navigation plumbing in `RootView` for programmatic detail push from the callout.

---

## Test / verification notes

- **Unit-testable pure logic** (put in `RightmoveKit` or a small helper so it's testable without UI):
  - short-price formatter: 450000→"£450k", 1_250_000→"£1.25m", 999→"£999", nil→primaryDisplay fallback.
  - mappable split: properties with nil lat/lng excluded; unmapped count correct.
  - cap arithmetic: with `totalPages` large, the loop stops at exactly 10 pages and sets
    `didCapMapLoad = true`; with `totalPages = 3`, it loads all 3 and leaves `didCapMapLoad = false`.
- **Idempotency**: simulate enter→exit→enter; assert `loadNextPage` isn't called for already-loaded
  indices (spy on a mock client / count fetches).
- **Manual/visual** (computer-use or local run): dense-area search shows clusters; cluster tap
  zooms and declusters; pin capsule callout shows card; "View details" pushes detail; pinned
  property shows accent; broad search shows the "showing first 240" note; a search with some
  coordinate-less results shows the "N not shown on map" note; re-running a search re-frames.
- **Politeness**: confirm the 250ms inter-page delay is present and the loop cancels on exit
  (network log shows no requests after switching back to list).

---

## Explicitly out of scope (deferred)

- "Search this area" / pan-to-search (decision 9) — requires bounds-based or reverse-geocoded
  search the current `locationIdentifier`+`radius` pipeline doesn't support.
- Persisting view mode across app restarts (decision 10 chose session-only).
- A side/bottom floating selection card instead of a popover callout (decision 4 chose callout).
