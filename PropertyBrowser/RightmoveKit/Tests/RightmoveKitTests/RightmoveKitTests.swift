import XCTest
@testable import RightmoveKit

final class RightmoveKitTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "html", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture \(name).html")
            throw RightmoveParseError.markerNotFound(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Search results

    func testSearchResultsParsing() throws {
        let page = try RightmoveParser.parseSearchResults(html: try fixture("search-highgate"))

        XCTAssertEqual(page.resultCount?.int, 345)
        XCTAssertEqual(page.properties.count, 25)
        XCTAssertEqual(page.pagination?.total?.int, 15)
        XCTAssertEqual(page.searchParameters?.locationIdentifier, "REGION^70315")

        let first = page.properties[0]
        XCTAssertEqual(first.propertyID, 89210640)
        XCTAssertEqual(first.price?.amount?.int, 1_500_000)
        XCTAssertEqual(first.price?.primaryDisplay, "£1,500,000")
        XCTAssertNotNil(first.location?.lat)
        XCTAssertNotNil(first.propertyUrl)
    }

    func testSearchDetectsPriceReductions() throws {
        let page = try RightmoveParser.parseSearchResults(html: try fixture("search-highgate"))
        let reduced = page.properties.filter { $0.listingUpdate?.listingUpdateReason == "price_reduced" }
        XCTAssertEqual(reduced.count, 7, "Expected 7 price_reduced listings in the fixture")
        XCTAssertTrue(reduced.contains { $0.propertyID == 152520503 })
    }

    func testEveryPropertyHasIdAndPrice() throws {
        let page = try RightmoveParser.parseSearchResults(html: try fixture("search-highgate"))
        for p in page.properties {
            XCTAssertNotNil(p.propertyID, "property missing integer id")
            XCTAssertNotNil(p.price?.amount?.int, "property \(p.id) missing price amount")
        }
    }

    // MARK: Featured-duplicate de-duplication

    func testFeaturedPropertyAppearsTwiceWithDistinctKeys() throws {
        let page = try RightmoveParser.parseSearchResults(html: try fixture("search-clapham-featured"))

        // 25 rows but only 24 distinct listings — one is repeated as "featured".
        XCTAssertEqual(page.properties.count, 25)
        XCTAssertEqual(Set(page.properties.compactMap { $0.propertyID }).count, 24)

        let dupes = page.properties.filter { $0.propertyID == 87848940 }
        XCTAssertEqual(dupes.count, 2, "Featured listing should appear twice")
        XCTAssertEqual(dupes.filter { $0.isFeatured }.count, 1)

        // listingKey disambiguates the two copies for SwiftUI identity.
        XCTAssertEqual(Set(page.properties.map { $0.listingKey }).count, 25)
        XCTAssertTrue(page.properties.contains { $0.listingKey == "87848940-featured" })
        XCTAssertTrue(page.properties.contains { $0.listingKey == "87848940" })
    }

    func testUniquePropertiesCollapsesFeaturedDuplicate() throws {
        let page = try RightmoveParser.parseSearchResults(html: try fixture("search-clapham-featured"))
        let unique = page.uniqueProperties

        // One row per real listing.
        XCTAssertEqual(unique.count, 24)
        XCTAssertEqual(Set(unique.compactMap { $0.propertyID }).count, 24)

        // The kept copy of the duplicated listing is the canonical (non-featured) one.
        let kept = unique.filter { $0.propertyID == 87848940 }
        XCTAssertEqual(kept.count, 1)
        XCTAssertFalse(kept[0].isFeatured, "Should prefer the in-place copy over the promoted one")

        // Snapshots built from the deduped page have no repeated propertyIDs.
        let snapshots = unique.compactMap { TrackedSnapshot(search: $0) }
        XCTAssertEqual(Set(snapshots.map { $0.propertyID }).count, snapshots.count)
    }

    // MARK: Property detail

    func testPropertyDetailParsing() throws {
        let detail = try RightmoveParser.parsePropertyDetail(html: try fixture("property-88856184"))

        XCTAssertEqual(detail.propertyID, 88856184)
        XCTAssertEqual(detail.status?.published, true)
        XCTAssertEqual(detail.status?.archived, false)
        XCTAssertFalse(detail.isDelisted)
        XCTAssertEqual(detail.prices?.primaryPrice, "£16,950,000")
        XCTAssertEqual(detail.address?.outcode, "N2")
        XCTAssertEqual(detail.propertySubType, "Penthouse")
        XCTAssertEqual(detail.bedrooms?.int, 5)
        XCTAssertEqual(detail.images?.count, 41)
        XCTAssertEqual(detail.floorplans?.count, 1)
        XCTAssertEqual(detail.listingHistory?.listingUpdateReason, "Added on 22/05/2026")
        XCTAssertFalse((detail.text?.description ?? "").isEmpty)
        XCTAssertNotNil(detail.images?.first?.url)
    }

    func testSoldSTCDetailIsRecognised() throws {
        let detail = try RightmoveParser.parsePropertyDetail(html: try fixture("property-sold-stc"))

        XCTAssertEqual(detail.propertyID, 170622311)
        // status alone says nothing — the SSTC signal is in tags.
        XCTAssertEqual(detail.status?.archived, false)
        XCTAssertEqual(detail.status?.published, true)
        XCTAssertEqual(detail.tags ?? [], ["SOLD_STC"])
        XCTAssertEqual(detail.listingState, .soldSTC)
        XCTAssertFalse(detail.isDelisted)
    }

    func testUnderOfferDetailIsRecognised() throws {
        let detail = try RightmoveParser.parsePropertyDetail(html: try fixture("property-under-offer"))

        XCTAssertEqual(detail.propertyID, 88533699)
        XCTAssertEqual(detail.tags ?? [], ["UNDER_OFFER"])
        XCTAssertEqual(detail.listingState, .underOffer)
        XCTAssertFalse(detail.isDelisted)
    }

    func testListingStateDerivation() {
        XCTAssertEqual(ListingState.derive(archived: false, published: true, tags: [], displayStatus: ""), .available)
        XCTAssertEqual(ListingState.derive(archived: false, published: true, tags: ["SOLD_STC"], displayStatus: nil), .soldSTC)
        XCTAssertEqual(ListingState.derive(archived: false, published: true, tags: ["UNDER_OFFER"], displayStatus: nil), .underOffer)
        XCTAssertEqual(ListingState.derive(archived: true, published: false, tags: ["SOLD_STC"], displayStatus: nil), .delisted)
        XCTAssertEqual(ListingState.derive(archived: nil, published: nil, tags: nil, displayStatus: "Under Offer"), .underOffer)
        XCTAssertEqual(ListingState.derive(archived: nil, published: nil, tags: nil, displayStatus: "Sold STC"), .soldSTC)
    }

    func testPageKindDetection() throws {
        XCTAssertEqual(RightmoveParser.detectKind(html: try fixture("search-highgate")), .searchResults)
        XCTAssertEqual(RightmoveParser.detectKind(html: try fixture("property-88856184")), .propertyDetail)
        XCTAssertEqual(RightmoveParser.detectKind(html: "<html>nope</html>"), .unknown)
    }

    // MARK: LossyNumber

    func testLossyNumberAcceptsIntStringAndDouble() throws {
        struct Box: Decodable { let n: LossyNumber }
        func decode(_ json: String) throws -> LossyNumber {
            try JSONDecoder().decode(Box.self, from: Data(json.utf8)).n
        }
        XCTAssertEqual(try decode(#"{"n": 345}"#).int, 345)
        XCTAssertEqual(try decode(#"{"n": "345"}"#).int, 345)
        XCTAssertEqual(try decode(#"{"n": 51.57}"#).double, 51.57)
        XCTAssertEqual(try decode(#"{"n": "£1,500,000"}"#).int, 1_500_000)
    }

    // MARK: Search URL

    func testSearchURLBuildsPaginatedURLWithSSTC() throws {
        let raw = "https://www.rightmove.co.uk/property-for-sale/find.html?locationIdentifier=REGION%5E70315&propertyTypes=flat&minBedrooms=2"
        let search = try XCTUnwrap(RightmoveSearchURL(string: raw))
        XCTAssertEqual(search.locationIdentifier, "REGION^70315")
        XCTAssertEqual(search.propertyTypes, ["flat"])

        let url = try XCTUnwrap(search.pageURL(index: 24))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = comps.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "index", value: "24")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "_includeSSTC", value: "on")))
        // index must not be duplicated
        XCTAssertEqual(items.filter { $0.name == "index" }.count, 1)
    }

    // MARK: Change detection

    private func snap(_ id: Int, _ amount: Int?, _ state: ListingState, at t: Double = 0) -> TrackedSnapshot {
        TrackedSnapshot(propertyID: id, priceAmount: amount,
                        priceDisplay: amount.map { "£\($0)" }, state: state,
                        capturedAt: Date(timeIntervalSince1970: t))
    }

    func testFirstSeenWhenNoPrevious() {
        let changes = ChangeDetector.diff(previous: nil, current: snap(1, 500_000, .available))
        XCTAssertEqual(changes.count, 1)
        guard case .firstSeen = changes.first else { return XCTFail("expected firstSeen") }
    }

    func testNoChangeWhenIdentical() {
        let a = snap(1, 500_000, .available, at: 0)
        let b = snap(1, 500_000, .available, at: 1000)
        XCTAssertTrue(ChangeDetector.diff(previous: a, current: b).isEmpty)
    }

    func testPriceReductionDetected() {
        let changes = ChangeDetector.diff(previous: snap(1, 500_000, .available),
                                          current: snap(1, 475_000, .available))
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].isPriceReduction)
        if case let .priceChanged(from, to, _, _) = changes[0] {
            XCTAssertEqual(from, 500_000); XCTAssertEqual(to, 475_000)
        } else { XCTFail("expected priceChanged") }
    }

    func testStatusChangeDetected() {
        let changes = ChangeDetector.diff(previous: snap(1, 500_000, .available),
                                          current: snap(1, 500_000, .underOffer))
        XCTAssertEqual(changes, [.stateChanged(from: .available, to: .underOffer)])
    }

    func testSimultaneousPriceAndStatusChange() {
        let changes = ChangeDetector.diff(previous: snap(1, 500_000, .available),
                                          current: snap(1, 480_000, .soldSTC))
        XCTAssertEqual(changes.count, 2)
    }

    func testSnapshotFromFixtures() throws {
        let page = try RightmoveParser.parseSearchResults(html: try fixture("search-highgate"))
        let s = try XCTUnwrap(TrackedSnapshot(search: page.properties[0]))
        XCTAssertEqual(s.propertyID, 89210640)
        XCTAssertEqual(s.priceAmount, 1_500_000)

        let detail = try RightmoveParser.parsePropertyDetail(html: try fixture("property-sold-stc"))
        let ds = try XCTUnwrap(TrackedSnapshot(detail: detail))
        XCTAssertEqual(ds.state, .soldSTC)
        XCTAssertEqual(ds.priceAmount, 600_000)   // parsed from "£600,000"
    }

    func testPageIndices() throws {
        let search = try XCTUnwrap(RightmoveSearchURL(string: "https://www.rightmove.co.uk/property-for-sale/find.html?locationIdentifier=REGION%5E70315"))
        XCTAssertEqual(search.pageIndices(forResultCount: 345), Array(stride(from: 0, to: 15 * 24, by: 24)))
        XCTAssertEqual(search.pageIndices(forResultCount: 0), [0])
    }
}
