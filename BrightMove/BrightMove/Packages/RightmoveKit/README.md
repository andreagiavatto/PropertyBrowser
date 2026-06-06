# RightmoveKit

The parsing core for PropertyBrowser — the riskiest, most breakage-prone part,
built and tested in isolation before any UI exists. Pure Swift + Foundation, no
networking yet, so you can validate it against saved HTML from many different
searches.

## What it does

Turns saved Rightmove HTML into typed Swift models:

- **Search-results pages** — data lives in a Next.js `__NEXT_DATA__` script tag.
  `RightmoveParser.parseSearchResults(html:)` → `SearchResultsPage` (result
  count, pagination, and per-property price, status, change-reason, location,
  images).
- **Property-detail pages** — data lives in `window.__PAGE_MODEL`, encoded with
  the `flatted` format (an index-referenced array graph). `RightmoveParser
  .parsePropertyDetail(html:)` unflattens it and returns `PropertyDetail`
  (full price, `status.published/archived` = the delisting signal, address,
  images, floorplans, description, location).
- **Search URLs** — `RightmoveSearchURL` parses a pasted results URL, exposes
  its filters, and builds paginated fetch URLs, always forcing `_includeSSTC=on`
  so pinned properties stay visible once Under Offer / Sold STC.

All numeric fields decode through `LossyNumber`, which accepts Int, Double, or
String, so a single inconsistent field on some future search won't fail the page.

## Validate it against your own searches

This is the point of building it first. On your Mac:

```sh
cd RightmoveKit
swift test          # runs the assertions against the two bundled fixtures
```

To throw new searches at it, save pages from your browser (⌘S → "Page Source"
is enough) and run the CLI:

```sh
swift run rmparse ~/Downloads/some-search.html ~/Downloads/some-property.html
```

It auto-detects each page type, prints a summary table (ids, prices, statuses,
change reasons), and exits non-zero if anything fails to parse — so you can
quickly confirm the parser holds across locations, property types, price bands,
and listings that are Under Offer / Sold STC / reduced.

Pages that come back as `SKIP … no __NEXT_DATA__ or __PAGE_MODEL` are almost
certainly Cloudflare challenge pages rather than real results — useful signal
for the later networking layer.

## Networking (the Cloudflare experiment)

`RightmoveClient` (an actor) fetches pages with Safari-like headers, a politeness
delay between requests, and an optional `Cookie` header you can copy from your
browser. `ChallengeDetector` classifies each response as real vs a Cloudflare /
bot-wall page. The open question is whether a plain cookieless request gets the
real JSON or a challenge — `netcheck` is how we find out:

```sh
cd RightmoveKit

# probe a search (builds the first page URL with _includeSSTC=on, then parses)
swift run netcheck --search "https://www.rightmove.co.uk/property-for-sale/find.html?locationIdentifier=REGION%5E70315&minBedrooms=2"

# probe a single property
swift run netcheck --property 88856184

# probe arbitrary URLs
swift run netcheck "https://www.rightmove.co.uk/property-for-sale/find.html?locationIdentifier=REGION%5E70315"

# retry with a browser session cookie (DevTools → Network → any request →
# Request Headers → copy the Cookie value)
swift run netcheck --cookie "cf_clearance=…; rmsessionid=…" --property 88856184
```

Each line reports `OK` (real page, with parsed summary), `CHALLENGED` (with the
reason, e.g. an HTTP 403/503 or a Cloudflare marker), or `HTTP-ERR`. If cookieless
probes come back `CHALLENGED` but the `--cookie` run is `OK`, the plan is: reuse
the browser session; if even that fails, fall back to a WKWebView fetch. Please
run a few and paste the output back.

## The app (`PropertyBrowser`)

The SwiftUI macOS app, built on top of the layers above. It's a SwiftPM
executable target so it runs with the same toolchain you've been using — no
Xcode project required:

```sh
cd RightmoveKit
swift run PropertyBrowser
```

(or open `Package.swift` in Xcode and run the **PropertyBrowser** scheme — Xcode
gives you the SwiftUI previews and a nicer debugger.)

Three sections in a `NavigationSplitView`:

- **Search** — paste a Rightmove results URL, browse the listings, pin any with
  the pin button.
- **Watchlist** — your pinned properties with current price/status and a
  *Refresh now* button. A daily `NSBackgroundActivityScheduler` also refreshes
  while the app is open.
- **Changes** — the chronological feed of price/status/delisting events.

The detail view loads the full listing (photo gallery, facts, key features,
description, a MapKit pin, floorplan, and a Swift Charts price-history graph once
there are at least two price points), with a *View on Rightmove* link.

It's unsandboxed (matches the plan: free network + cookie access, local data
store). Note the daily schedule only fires while the app is running — refresh on
launch and the manual button cover the rest.

## Tracking & persistence (`PropertyStore`)

The tracking logic is split so the part with real logic stays testable without a
database:

- **Pure diff core** (in `RightmoveKit`, no SwiftData): `TrackedSnapshot` is a
  point-in-time capture built from either a search row or a detail page;
  `ChangeDetector.diff(previous:current:)` turns two snapshots into
  `PropertyChange` values (firstSeen / priceChanged / stateChanged, where a
  state change also covers under-offer, sold-STC, delisting and relisting).
- **SwiftData store** (`PropertyStore`, macOS 14): `PinnedProperty` (latest
  known state) and an append-only `PropertyEvent` log. `TrackingStore` pins
  properties, and `apply(_ snapshot:)` diffs against the last known state,
  appends events, and updates the pin — returning the events it recorded.
  `recentChanges()` is the global feed.

```swift
let store = try TrackingStore.inMemory()                 // or TrackingStore(context:)
store.pin(TrackedSnapshot(detail: detail)!)              // records firstSeen
let events = store.apply(TrackedSnapshot(search: row)!)  // records price/status changes
let feed = store.recentChanges()                         // newest first
```

`swift test` covers both: pure diff cases (price drop, status change, both at
once, snapshots from the HTML fixtures) and the store against an in-memory
SwiftData container (pinning, idempotency, event recording, unpin cascade, feed
ordering).

## Layout

```
Sources/RightmoveKit/
  LossyNumber.swift        tolerant numeric decoding
  SearchModels.swift       search-results Codable models
  DetailModels.swift       property-detail Codable models
  HTMLExtractor.swift      pulls JSON out of the two page shapes
  Flatted.swift            flatted (npm) decoder for the detail page
  RightmoveParser.swift    top-level parse entry points + page-kind detection
  RightmoveSearchURL.swift saved-search URL + pagination
  ListingState.swift       available / underOffer / soldSTC / delisted
  RightmoveClient.swift     async fetch + challenge detection
  TrackedSnapshot.swift     point-in-time capture (from search row or detail)
  ChangeDetector.swift      pure diff → PropertyChange
Sources/PropertyStore/
  Models.swift              PinnedProperty + PropertyEvent @Models (SwiftData)
  TrackingStore.swift       pin / unpin / apply snapshot → events / feed
Sources/rmparse/main.swift CLI parser validator
Sources/netcheck/main.swift CLI live-fetch probe
Tests/RightmoveKitTests/   XCTest + HTML fixtures
```

## Listing state

`ListingState` (available / underOffer / soldSTC / delisted / unknown) is derived
per property:

- **Detail page** — Sold STC / Under Offer come from `propertyData.tags`
  (e.g. `["SOLD_STC"]`); full removal comes from `status` (`archived`/
  `published`). `status` alone does **not** reflect SSTC, so both are needed.
- **Search page** — from `displayStatus` and/or per-property `tags`.

Confirmed against real detail pages: `SOLD_STC` and `UNDER_OFFER`. Still
inferred until a sample confirms it: the search-side `displayStatus` strings
(the bundled searches are all available). Unknown tags map to `.unknown` so they
surface during validation rather than being silently mis-labelled.

## Known unknowns (validate next)

- Search-results representation of Under Offer / Sold STC (feed `rmparse` a
  search that includes some).
- Whether a cookieless `URLSession` request gets a Cloudflare challenge (a
  networking concern, not a parsing one).
