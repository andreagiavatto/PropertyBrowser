# Address Resolver — Implementation Plan

Resolve a Rightmove listing's **full address** (house number + street + postcode) from the
data BrightMove already holds, replacing the manual "hunt down the house in Google Street
View" workflow with a ranked, one-click-confirmable candidate list.

This plan is grounded in the current code: `PropertyDetailView` already fetches a
`PropertyDetail` (with `address.outcode`/`incode`/`displayAddress`, `location.lat`/`lng`,
`bedrooms`, `propertySubType`) and already resolves a `FloorArea` on-demand via
`FloorplanAnalyser.extract(...)`. Persistence is **SwiftData** (`@Model`, see
`PropertyStore`). PATMA is integrated via `PATMAClient`, with its credential held in
`@AppStorage("patma.sessionid")`. MapKit / `CLGeocoder` are already linked. Target macOS 15.

---

## Agreed design (reference)

1. **Backbone:** PATMA free-check → **EPC-register attribute match** → Google Street View
   only as a tie-breaker. EPC + Land Registry was considered; **v1 is EPC-only** (one API,
   no SPARQL). Land Registry sold-price matching is a documented future upgrade.
2. **Trigger:** on-demand, per property (a button in `PropertyDetailView`), **with a
   persistent cache** so re-opening a property is instant and a local store builds over time.
3. **Floor area:** reuse the existing `FloorplanAnalyser.extract(...)`. Only the real OCR
   value (`isApproximate == false`) is trusted for matching; the price÷£-per-sqft fallback is
   circular and treated as "no area signal."
4. **Candidate scoping (the key trick):** Rightmove frequently withholds `incode` by design,
   so we do **not** assume a full postcode. Query EPC by the always-present **outcode**, then
   filter to certificates whose address contains the **street name** parsed from
   `displayAddress`. That collapses thousands → one street (~tens); area + beds + type then
   pick the house.
5. **Scoring (defaults):** floor area within **±10%** of EPC `total-floor-area`; Rightmove
   `propertySubType` mapped onto EPC `property-type` / `built-form`; bedroom count corroborated
   loosely against EPC `number-habitable-rooms` (EPC has no clean bedroom field). Latest
   certificate per address wins when an address has several.
6. **Result UX:** always show candidate addresses **ranked by match score**, each with the
   matched signals visible and a **one-click Google Street View deep-link** to that exact
   frontage. A single confident hit shows one row; you still confirm visually like today, but
   the hunting is done.
7. **Street View link:** geocode the EPC candidate address with `CLGeocoder` → `lat,lng`, then
   build a Street View pano URL (`https://maps.google.com/maps?q=&layer=c&cbll={lat},{lng}`)
   so the link lands on the house, not a map.
8. **Commit:** the top candidate **auto-saves as the resolved address, flagged
   `unconfirmed`**; your click (after the Street View glance) upgrades it to `confirmed`. The
   full ranked candidate list is retained either way.
9. **Credential:** EPC token read from a `ProcessInfo` **env var** first (prototype path),
   falling back to `@AppStorage("epc.token")` to match the existing PATMA convention.
10. **Cache model:** a new SwiftData `@Model ResolvedAddress` keyed by a unique `propertyID`,
    **decoupled from `PinnedProperty`** (you resolve listings you haven't pinned).

---

## Data flow

```
PropertyDetailView (already has: outcode, incode?, displayAddress, lat/lng,
                    bedrooms, propertySubType, floorArea)
        │
        ▼
AddressResolver.resolve(detail:, floorArea:)
        │
        ├─ cache hit (ResolvedAddress by propertyID)? → return stored candidates
        │
        ├─ 1. street = parseStreet(displayAddress)
        │     outcode = address.outcode  (required; else bail with .insufficientInput)
        │
        ├─ 2. EPCClient.certificates(outcode:) → [EPCCertificate]
        │
        ├─ 3. filter: cert.address contains street (normalised)
        │     dedupe to latest cert per address (by lodgement date)
        │
        ├─ 4. score each candidate (area ±10%, type/built-form, habitable rooms)
        │     drop zero-signal candidates; sort desc
        │
        ├─ 5. geocode top-N addresses (CLGeocoder) → attach Street View URL
        │
        └─ 6. persist ResolvedAddress(top = unconfirmed, candidates = […]) → return
```

---

## New files

### 1. `Packages/RightmoveKit/Sources/RightmoveKit/EPCClient.swift`

A small, testable client for the EPC Domestic Energy Performance API
(`https://epc.opendatacommunities.org/api/v1/domestic/search`). Lives in `RightmoveKit`
alongside `PATMAClient`'s sibling concerns so it's unit-testable without the app.

```
public struct EPCCertificate: Decodable, Sendable {
    public let address: String          // "address" (full line)
    public let postcode: String?
    public let propertyType: String?    // "property-type"   e.g. "House", "Flat"
    public let builtForm: String?       // "built-form"      e.g. "Semi-Detached"
    public let totalFloorArea: Double?  // "total-floor-area" (m²)
    public let habitableRooms: Int?     // "number-habitable-rooms"
    public let lodgementDate: Date?     // "lodgement-date"   (latest-wins dedupe)
    public let uprn: String?            // "uprn" when present
}

public struct EPCClient: Sendable {
    public static let endpoint = URL(string:
        "https://epc.opendatacommunities.org/api/v1/domestic/search")!
    public var token: String            // Basic auth: base64("email:token") OR raw API key
    public var timeout: TimeInterval

    /// Query by outcode (postcode prefix). EPC paginates; follow `search-after` until
    /// exhausted or a sane cap (street filter happens client-side).
    public func certificates(outcode: String) async throws -> [EPCCertificate]
}
```

Notes:
- Auth header is `Authorization: Basic <base64(email:token)>` and `Accept: application/json`.
- The API accepts a partial `postcode` (the outcode), returning all certs in it — paginate
  via the `X-Next-Search-After` header / `search-after` param. Cap pages defensively.
- Date parsing mirrors the lenient style already used in `ListingHistory.parsedDate`.

### 2. `Classes/Controllers/AddressResolver.swift`

The orchestration + scoring service. App-layer (uses `CLGeocoder`, SwiftData), depends on
`EPCClient` from the kit.

```
struct AddressCandidate: Identifiable {
    let id = UUID()
    let address: String
    let postcode: String?
    let uprn: String?
    let score: Double                 // 0…1
    let matchedSignals: [String]      // ["floor area 84 m² (±3%)", "Semi-Detached", "3 rooms"]
    var streetViewURL: URL?           // filled after geocode
}

enum ResolveOutcome {
    case resolved([AddressCandidate]) // ranked, non-empty
    case noMatch                      // street found, no EPC certs matched
    case insufficientInput            // no outcode / no street / no usable area
}

enum AddressResolver {
    static func resolve(detail: PropertyDetail,
                        floorArea: FloorArea?,
                        epc: EPCClient,
                        store: ResolvedAddressStore) async -> ResolveOutcome
}
```

Scoring (transparent, additive; tune later):
- **Floor area** (strongest): if real OCR area present, `1 - min(1, |epcArea-ocrArea|/ocrArea)`,
  hard-drop above ±10% delta. Skip if area is `nil` or `isApproximate`.
- **Type/built-form:** map `propertySubType` → EPC vocab; full point on match, partial on
  family match (e.g. "Terraced House" vs "End-Terrace").
- **Habitable rooms:** soft bonus when `habitableRooms ≈ bedrooms + {1,2}` (living/kitchen).
- Normalise to 0…1; sort desc; keep top ~5.

Street-name parsing: take the segment of `displayAddress` before the first comma, strip
unit/flat prefixes, normalise case/whitespace/`St`↔`Street` etc. A few unit tests pin the
tricky cases (`"Flat 2, Acre Lane, London"` → `"Acre Lane"`).

Street View URL: `CLGeocoder().geocodeAddressString(candidate.address + ", " + postcode)`
→ first placemark coord → `https://maps.google.com/maps?q=&layer=c&cbll={lat},{lng}`.
Geocode only the displayed top-N to stay within `CLGeocoder` rate limits; do it lazily.

### 3. `Packages/RightmoveKit/Sources/PropertyStore/ResolvedAddress.swift`

SwiftData model + a thin store, mirroring `TrackingStore`'s shape.

```
@Model public final class ResolvedAddress {
    @Attribute(.unique) public var propertyID: Int
    public var resolvedAddress: String?     // the committed top candidate
    public var postcode: String?
    public var uprn: String?
    public var confirmationRaw: String      // "unconfirmed" | "confirmed"
    public var candidatesJSON: Data?        // encoded [AddressCandidate-lite]
    public var method: String               // "epc" (future: "epc+lr", "streetview")
    public var resolvedAt: Date
    public var confirmedAt: Date?
}
```

Store methods: `lookup(propertyID:)`, `upsert(...)`, `confirm(propertyID:choosing:)`.
Register the model in the same `ModelContainer` schema as `PinnedProperty` / `PropertyEvent`.

---

## Touched existing files

### `Classes/SubViews/PropertyDetailView.swift`
- Add a **"Resolve address"** button near the address row (`Format.oneLine(d.address?.displayAddress)`,
  ~line 168). Disabled with a hint when `address.outcode` is missing.
- Reuse the already-resolved `@State floorArea` (computed ~line 544) — pass it straight into
  `AddressResolver.resolve`. No second OCR pass.
- New `@State resolveOutcome: ResolveOutcome?` drives a results section: ranked candidate
  rows, each showing `matchedSignals`, a **Street View** link button, and a **"This one"**
  confirm button that calls `store.confirm(...)`.
- On appear, pre-load any cached `ResolvedAddress` so prior work shows instantly (confirmed
  badge vs "unconfirmed — tap to confirm").
- `@AppStorage("epc.token")` (fallback) + read `ProcessInfo.processInfo.environment["EPC_TOKEN"]`
  first in the resolver's client factory.

### `BrightMoveApp.swift` / wherever the `ModelContainer` schema is declared
- Add `ResolvedAddress.self` to the schema.

---

## Edge cases & failure modes

- **No outcode** → button disabled / `.insufficientInput`. (Outcode is near-always present on
  detail pages; this is the genuine floor.)
- **No usable floor area** (no floorplan, or only the approximate fallback) → still rank on
  type + rooms; expect more ties → that's exactly what the Street View glance resolves.
- **Street not in EPC** (never-certificated, e.g. some new builds) → `.noMatch`; surface a
  plain Street View link at the fuzzed coordinate so you fall back to today's manual method.
- **EPC area ≠ floorplan area:** EPC measures gross internal area to RdSAP conventions; the
  ±10% tolerance absorbs typical divergence. Tunable constant.
- **Multiple certs per address:** keep the latest by `lodgement-date`.
- **CLGeocoder throttling:** geocode lazily for visible candidates only; cache the coord on
  the candidate; never block the ranked list on geocoding.
- **Token missing/invalid:** EPC returns 401 → show a one-line "Add your EPC API token"
  affordance rather than a silent empty result.

---

## Future upgrades (explicitly out of v1)

- **Land Registry Price Paid** via SPARQL, cross-referenced against the sale price/date PATMA
  already returns — a near-unique sale fingerprint that would disambiguate the remaining EPC
  ties without any Street View glance.
- **PATMA free-check:** inspect whether `load_info`'s response already carries a resolved
  address/UPRN we could surface for zero new calls; promote to a pre-EPC fast path if so.
- **Vision Street View matching:** auto-compare the listing's front-of-house photo to Street
  View panoramas — the full automation of today's manual step. Highest effort, most fragile;
  only worth it if EPC+LR still leaves frequent ties.

---

## Build order

1. `EPCClient` + decode model + a unit test against a saved JSON fixture for one outcode.
2. Street-name parser + scoring, unit-tested in isolation (no network).
3. `ResolvedAddress` model + store; register in the schema.
4. `AddressResolver` wiring `EPCClient` → scoring → `CLGeocoder` → store.
5. `PropertyDetailView` UI: button, ranked rows, Street View links, confirm action, cache
   pre-load.
6. Manual pass on ~10 real listings (mix of: has incode, no incode, no floorplan, new build)
   to tune the ±10% tolerance and the room-count bonus.
```
