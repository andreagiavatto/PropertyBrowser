import Foundation
import CoreLocation
import RightmoveKit
import PropertyStore

/// Outcome of an address-resolution attempt, surfaced by `PropertyDetailView`.
enum ResolveOutcome {
    /// Ranked, non-empty candidates (best first), already persisted.
    case resolved([StoredCandidate])
    /// Street parsed and EPC queried, but nothing on the street matched.
    case noMatch(fallback: URL?)
    /// Missing the inputs we need (no outcode, or no street).
    case insufficientInput
    /// Network / auth / config problem. `message` is user-facing.
    case failed(message: String)
}

/// Reads the EPC API token from the environment first (prototype path), then
/// falls back to the `@AppStorage("epc.token")` default, mirroring how the
/// PATMA `sessionid` is held.
enum EPCConfig {
    static var token: String? {
        return "At70nN5qUyFNf2Q0rUEzMINcRGPBjdCD5GcHPhoBhlEvCm9LGpF65AFppXr2gydR"
//        if let env = ProcessInfo.processInfo.environment["EPC_TOKEN"],
//           !env.trimmingCharacters(in: .whitespaces).isEmpty {
//            return env
//        }
//        let stored = UserDefaults.standard.string(forKey: "epc.token")
//        return (stored?.isEmpty == false) ? stored : nil
    }
}

/// Ties EPC search → scoring → geocoding → cache for one property, on demand.
@MainActor
enum AddressResolver {

    /// Resolve a listing's full address. Persists the ranked result (top
    /// candidate auto-saved as `unconfirmed`) and returns it.
    ///
    /// Primary path: match the listing's Land-Registry sold-price history (fetched
    /// from Rightmove) against Price Paid Data for its postcode to infer the exact
    /// civic number. Falls back to EPC matching when the listing has no usable
    /// sale history (e.g. never sold / new build) or the page model lacks the ids.
    static func resolve(detail: PropertyDetail,
                        floorArea: FloorArea?,
                        store: ResolvedAddressStore,
                        housePrices: HousePricesClient = HousePricesClient()) async -> ResolveOutcome {
        if let outcome = await resolveByPricePaid(detail: detail, store: store,
                                                  housePrices: housePrices) {
            return outcome
        }
        return await resolveByEPC(detail: detail, floorArea: floorArea,
                                  store: store, housePrices: housePrices)
    }

    // MARK: - Land Registry price-paid resolution (primary)

    /// Infer the civic number from the listing's sold-price fingerprint: fetch the
    /// property's sold history (Rightmove) and the postcode's Price Paid records
    /// (Land Registry), then match. Returns nil to signal the caller should fall
    /// back to EPC — missing ids/postcode, no sale history, a failed fetch, or no
    /// price match.
    private static func resolveByPricePaid(
        detail: PropertyDetail,
        store: ResolvedAddressStore,
        housePrices: HousePricesClient
    ) async -> ResolveOutcome? {
        guard let encId = detail.encId,
              let deliveryPointId = detail.address?.deliveryPointId?.int,
              let postcode = detail.address?.fullPostcode,
              let propertyID = detail.propertyID else {
            return nil
        }

        let result: CivicNumberLookup.Result
        do {
            result = try await CivicNumberLookup.identify(
                deliveryPointId: String(deliveryPointId),
                encId: encId,
                propertyID: propertyID,
                postcode: postcode)
        } catch {
            return nil   // sold-history or Land Registry unavailable → try EPC
        }
        guard !result.ranked.isEmpty else { return nil }   // no fingerprint → EPC

        // Denominator for the match score: how many of the listing's sales had
        // both a year and a price to match on.
        let wantedCount = result.soldHistory.soldPropertyTransactions
            .filter { $0.year != nil && $0.price != nil }.count

        // The sold-history fetch already returns the listing's own house-prices
        // page path ("/house-prices/details/{uuid}"), so the link to its previous
        // listings comes for free here — no extra request or matching needed.
        let historyURLString = result.soldHistory.soldPropertyUrlPath.map { path in
            path.hasPrefix("http") ? path : HousePricesLink.host + path
        }

        var stored: [StoredCandidate] = []
        for id in result.ranked {
            let address = composeCivicAddress(id, postcode: postcode)
            let svURL = await streetViewURL(address: address, postcode: postcode)
            stored.append(StoredCandidate(
                address: address,
                postcode: id.postcode ?? postcode,
                uprn: nil,
                score: wantedCount > 0
                    ? min(1.0, Double(id.matchedTransactions) / Double(wantedCount))
                    : 0,
                matchedSignals: civicSignals(id),
                streetViewURLString: svURL?.absoluteString,
                rightmoveHistoryURLString: historyURLString))
        }

        // `soldPropertyUrlPath` is usually present, but when it's missing fall
        // back to the same postcode-page lookup the EPC path uses so a "previous
        // listings" link is always offered (pinned card, else the postcode page).
        if historyURLString == nil {
            let links = await housePrices.links(
                for: stored.map { (address: $0.address, postcode: $0.postcode ?? "") })
            for i in stored.indices {
                stored[i].rightmoveHistoryURLString = links[i]?.absoluteString
            }
        }

        store.upsert(propertyID: propertyID, candidates: stored, method: "landregistry")
        return .resolved(stored)
    }

    /// Compose a display address from a Price Paid identification + postcode,
    /// e.g. "Flat 2, 5 Brixton Hill, SW2 1RW".
    private static func composeCivicAddress(
        _ id: PricePaidMatcher.Identification, postcode: String
    ) -> String {
        let number = [id.saon, id.paon].compactMap { $0 }.joined(separator: ", ")
        let line = [number, id.street ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .capitalized
        return [line, postcode].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func civicSignals(_ id: PricePaidMatcher.Identification) -> [String] {
        var signals: [String] = []
        if let price = id.lastSoldPrice, let year = id.lastSoldYear {
            signals.append("last sold £\(price.formatted()) in \(String(year))")
        }
        signals.append("\(id.matchedTransactions) sold-price \(id.matchedTransactions == 1 ? "match" : "matches")")
        return signals
    }

    // MARK: - EPC resolution (fallback)

    private static func resolveByEPC(detail: PropertyDetail,
                                     floorArea: FloorArea?,
                                     store: ResolvedAddressStore,
                                     housePrices: HousePricesClient) async -> ResolveOutcome {

        // Inputs.
        let street = StreetName.parse(from: detail.address?.displayAddress)
        guard let outcode = detail.address?.outcode?.trimmingCharacters(in: .whitespaces),
              !outcode.isEmpty, let street, !street.isEmpty else {
            return .insufficientInput
        }
        guard let token = EPCConfig.token else {
            return .failed(message: "Add your EPC API token to resolve addresses.")
        }

        // Only the real OCR area is trustworthy; the price-derived fallback is
        // circular, so it's treated as "no area signal".
        let areaSqm: Double? = (floorArea?.isApproximate == false) ? floorArea?.sqm : nil

        // EPC lookup is two-stage. The search endpoint returns no physical data,
        // so we (1) search, (2) shortlist to this street, then (3) fetch each
        // survivor's full certificate for floor area / type / rooms.
        //
        // Prefer an exact full-postcode search when the page model has one: it's
        // precise and avoids paging through a common street name nationwide. Fall
        // back to a street-name `address` search (filtered to the outcode) only
        // when no full postcode is available.
        let client = EPCClient(token: token)
        let certs: [EPCCertificate]
        do {
            let results: [EPCSearchResult]
            if let postcode = detail.address?.fullPostcode {
                results = try await client.search(postcode: postcode)
            } else {
                results = try await client.search(address: street)
            }
            let shortlist = EPCMatcher.shortlist(results, street: street, outcode: outcode)
            var fetched: [EPCCertificate] = []
            for result in shortlist {
                // Skip a single bad certificate rather than failing the whole resolve.
                if let cert = try? await client.detailedCertificate(for: result) {
                    fetched.append(cert)
                }
            }
            certs = fetched
        } catch let e as EPCClient.Failure {
            return .failed(message: e.description)
        } catch {
            return .failed(message: "EPC request failed: \(error.localizedDescription)")
        }

        // Rank (outcode re-imposed defensively; shortlist already applied it).
        let ranked = EPCMatcher.rank(
            certificates: certs,
            street: street,
            floorAreaSqm: areaSqm,
            bedrooms: detail.bedrooms?.int,
            propertySubType: detail.propertySubType,
            outcode: outcode)

        guard !ranked.isEmpty else {
            // Nothing matched: still hand back a Street View link at the listing's
            // (fuzzed) coordinate so the manual method remains one click away.
            let fallback = detail.location.flatMap { loc -> URL? in
                guard let lat = loc.lat, let lng = loc.lng else { return nil }
                return StreetViewLink.pano(lat: lat, lng: lng)
            }
            return .noMatch(fallback: fallback)
        }

        // Geocode the top candidates for precise Street View links.
        var stored: [StoredCandidate] = []
        for candidate in ranked {
            guard let address = candidate.certificate.address else { continue }
            let postcode = candidate.certificate.postcode
            let svURL = await streetViewURL(address: address, postcode: postcode)
            stored.append(StoredCandidate(
                address: address,
                postcode: postcode,
                uprn: candidate.certificate.uprn,
                score: candidate.score,
                matchedSignals: candidate.matchedSignals,
                streetViewURLString: svURL?.absoluteString))
        }

        // EPC matches carry no sold-history link, so derive each candidate's
        // house-prices link from its postcode page (degrading to the postcode
        // page itself when the exact card can't be pinned).
        let historyLinks = await housePrices.links(
            for: stored.map { (address: $0.address, postcode: $0.postcode ?? "") })
        for i in stored.indices {
            stored[i].rightmoveHistoryURLString = historyLinks[i]?.absoluteString
        }

        guard let propertyID = detail.propertyID else {
            return .failed(message: "Listing has no property ID to cache against.")
        }
        store.upsert(propertyID: propertyID, candidates: stored)
        return .resolved(stored)
    }

    // MARK: - Land Registry civic-number cross-check

    /// Pin the exact civic number for a listing by matching its Land-Registry
    /// sold-price history (via Rightmove) against Price Paid Data for its
    /// postcode. Intended to run after an EPC street/postcode match is selected.
    ///
    /// Returns nil when the page model lacks the `encId` / `deliveryPointId` /
    /// full postcode needed. `.best` is the confident single address (or nil if
    /// ambiguous); `.ranked` lists all candidates for manual choice.
    static func crossCheckCivicNumber(
        detail: PropertyDetail,
        cookie: String? = nil
    ) async -> CivicNumberLookup.Result? {
        guard let encId = detail.encId,
              let deliveryPointId = detail.address?.deliveryPointId?.int,
              let postcode = detail.address?.fullPostcode else {
            return nil
        }
        return try? await CivicNumberLookup.identify(
            deliveryPointId: String(deliveryPointId),
            encId: encId,
            propertyID: detail.propertyID,
            postcode: postcode,
            soldHistoryClient: SoldHistoryClient(cookie: cookie))
    }

    // MARK: - Geocoding

    private static let geocoder = CLGeocoder()

    /// Geocode the address to a precise Street View pano URL; fall back to a
    /// Maps search link if geocoding yields nothing.
    private static func streetViewURL(address: String, postcode: String?) async -> URL? {
        let query = StreetViewLink.geocodeQuery(address: address, postcode: postcode)
        if let coord = await geocode(query),
           let pano = StreetViewLink.pano(lat: coord.latitude, lng: coord.longitude) {
            return pano
        }
        return StreetViewLink.search(address: query)
    }

    private static func geocode(_ query: String) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(query) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.location?.coordinate)
            }
        }
    }
}
