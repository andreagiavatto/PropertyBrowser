import XCTest
import Foundation
@testable import RightmoveKit

final class SearchCriteriaTests: XCTestCase {

    // MARK: Typeahead URL

    func testTypeAheadURL() {
        let url = RightmoveTypeAhead.url(for: "Richmond")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "los.rightmove.co.uk")
        XCTAssertEqual(url?.path, "/typeahead")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(dict["query"], "Richmond")
        XCTAssertEqual(dict["limit"], "10")
        XCTAssertEqual(dict["exclude"], "")
    }

    func testTypeAheadURLEncodesSpaces() {
        // A multi-word query must be percent-encoded in the query string.
        XCTAssertTrue(RightmoveTypeAhead.url(for: "St Albans")!.absoluteString.contains("query=St%20Albans"))
    }

    func testTypeAheadURLRejectsBlank() {
        XCTAssertNil(RightmoveTypeAhead.url(for: "   "))
    }

    func testTypeAheadResponseDecodesAndAssemblesIdentifier() throws {
        // Real shape from los.rightmove.co.uk/typeahead: matches with id + type.
        let json = """
        {"matches":[
            {"id":85386,"type":"REGION","displayName":"Richmond, Surrey"},
            {"id":1126,"type":"OUTCODE","displayName":"TW9"},
            {"id":"1472263","type":"POSTCODE","displayName":"TW9 1AA"}
        ]}
        """
        let decoded = try JSONDecoder().decode(TypeAheadResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.matches.count, 3)
        XCTAssertEqual(decoded.matches[0].locationIdentifier, "REGION^85386")
        XCTAssertEqual(decoded.matches[0].displayName, "Richmond, Surrey")
        XCTAssertEqual(decoded.matches[1].locationIdentifier, "OUTCODE^1126")
        // id supplied as a string still works.
        XCTAssertEqual(decoded.matches[2].locationIdentifier, "POSTCODE^1472263")
    }

    // MARK: Criteria -> URL

    func testCriteriaBuildsURLWithAllFilters() throws {
        let criteria = RightmoveSearchCriteria(
            locationIdentifier: "REGION^85386",
            displayName: "Richmond, Surrey",
            radius: .half,
            minBedrooms: "2",
            minPrice: nil,
            maxPrice: "500000",
            propertyTypes: [.detached, .semiDetached]
        )
        let search = try XCTUnwrap(RightmoveSearchURL(criteria: criteria))
        let items = Dictionary(uniqueKeysWithValues: search.queryItems.map { ($0.name, $0.value) })

        XCTAssertEqual(items["locationIdentifier"], "REGION^85386")
        XCTAssertEqual(items["radius"], "0.5")
        XCTAssertEqual(items["minBedrooms"], "2")
        XCTAssertEqual(items["maxPrice"], "500000")
        XCTAssertNil(items["minPrice"] ?? nil)              // omitted when unset
        XCTAssertEqual(items["propertyTypes"], "detached,semi-detached")
        // Sort is always emitted; defaults to highest price ("2").
        XCTAssertEqual(items["sortType"], "2")
    }

    func testCriteriaOmitsUnsetFilters() throws {
        let criteria = RightmoveSearchCriteria(
            locationIdentifier: "OUTCODE^2502",
            displayName: "SW1A",
            radius: .thisAreaOnly
        )
        let search = try XCTUnwrap(RightmoveSearchURL(criteria: criteria))
        let names = Set(search.queryItems.map(\.name))
        // sortType is always present even when every optional filter is unset.
        XCTAssertEqual(names, ["locationIdentifier", "radius", "sortType"])
    }

    func testCriteriaEmitsChosenSortType() throws {
        for order in SortOrder.allCases {
            let criteria = RightmoveSearchCriteria(
                locationIdentifier: "REGION^85386", displayName: "Richmond",
                radius: .one, sortOrder: order
            )
            let search = try XCTUnwrap(RightmoveSearchURL(criteria: criteria))
            let items = Dictionary(uniqueKeysWithValues: search.queryItems.map { ($0.name, $0.value) })
            XCTAssertEqual(items["sortType"], order.rawValue)
        }
    }

    func testCriteriaWithoutLocationFailsToBuild() {
        XCTAssertNil(RightmoveSearchURL(criteria: RightmoveSearchCriteria()))
    }

    func testFirstPageURLForcesIncludeSSTC() throws {
        let criteria = RightmoveSearchCriteria(
            locationIdentifier: "REGION^85386", displayName: "Richmond", radius: .one
        )
        let search = try XCTUnwrap(RightmoveSearchURL(criteria: criteria))
        let url = try XCTUnwrap(search.firstPageURL())
        XCTAssertTrue(url.absoluteString.contains("_includeSSTC=on"))
        XCTAssertTrue(url.absoluteString.contains("index=0"))
    }

    // MARK: Criteria persistence round-trip

    func testCriteriaCodableRoundTrip() throws {
        let criteria = RightmoveSearchCriteria(
            locationIdentifier: "REGION^85386",
            displayName: "Richmond, Surrey",
            radius: .three,
            minBedrooms: "3",
            minPrice: "250000",
            maxPrice: "750000",
            propertyTypes: [.flat, .terraced],
            sortOrder: .newestListed
        )
        let data = try JSONEncoder().encode(criteria)
        let restored = try JSONDecoder().decode(RightmoveSearchCriteria.self, from: data)
        XCTAssertEqual(criteria, restored)
        XCTAssertEqual(restored.sortOrder, .newestListed)
    }

    /// Criteria persisted before `sortOrder` existed (no key in the JSON) must
    /// still decode, defaulting to highest price rather than failing the whole
    /// decode and wiping the user's saved search.
    func testLegacyCriteriaWithoutSortOrderDecodes() throws {
        let legacyJSON = """
        {
          "locationIdentifier": "REGION^85386",
          "displayName": "Richmond, Surrey",
          "radius": "1.0",
          "minBedrooms": "2",
          "propertyTypes": ["flat"]
        }
        """
        let restored = try JSONDecoder().decode(
            RightmoveSearchCriteria.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(restored.sortOrder, .highestPrice)
        XCTAssertEqual(restored.locationIdentifier, "REGION^85386")
        XCTAssertEqual(restored.minBedrooms, "2")
    }

    func testDefaultSortOrderIsHighestPrice() {
        XCTAssertEqual(RightmoveSearchCriteria().sortOrder, .highestPrice)
    }
}
