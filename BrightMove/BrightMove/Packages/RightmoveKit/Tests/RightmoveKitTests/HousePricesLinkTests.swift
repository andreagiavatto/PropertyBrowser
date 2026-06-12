import XCTest
@testable import RightmoveKit

final class HousePricesLinkTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "html", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture \(name).html")
            throw RightmoveParseError.markerNotFound(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - URL building

    func testSlug() {
        XCTAssertEqual(HousePricesLink.slug(forPostcode: "SW11 2EZ"), "sw11-2ez")
        XCTAssertEqual(HousePricesLink.slug(forPostcode: "  n8 7ra "), "n8-7ra")
        XCTAssertEqual(HousePricesLink.slug(forPostcode: "M20-4AP"), "m20-4ap")
        XCTAssertNil(HousePricesLink.slug(forPostcode: "   "))
    }

    func testSplitLocationIdentifier() {
        let split = HousePricesLink.splitLocationIdentifier("POSTCODE^3704430")
        XCTAssertEqual(split?.type, "POSTCODE")
        XCTAssertEqual(split?.id, "3704430")
        XCTAssertNil(HousePricesLink.splitLocationIdentifier("REGION"))
        XCTAssertNil(HousePricesLink.splitLocationIdentifier("^123"))
    }

    func testPostcodePageURL() {
        let url = HousePricesLink.postcodePageURL(
            postcode: "SW11 2EZ", locationType: "POSTCODE", locationId: "3704430")
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://www.rightmove.co.uk/house-prices/sw11-2ez.html?"))
        XCTAssertTrue(s.contains("locationType=POSTCODE"))
        XCTAssertTrue(s.contains("locationId=3704430"))
        XCTAssertTrue(s.contains("sortBy=DEED_DATE"))
    }

    func testPostcodePageURLWithoutLocationId() {
        let s = HousePricesLink.postcodePageURL(postcode: "SW11 2EZ")!.absoluteString
        XCTAssertTrue(s.contains("/house-prices/sw11-2ez.html"))
        XCTAssertFalse(s.contains("locationId"))
    }

    // MARK: - Card parsing

    func testParseCardsFromFixture() throws {
        let html = try fixture("house-prices-sw11-2ez")
        let cards = HousePricesLink.parseCards(html: html)

        XCTAssertEqual(cards.count, 9)
        let card21 = cards.first { $0.address.hasPrefix("21,") }
        XCTAssertNotNil(card21)
        XCTAssertEqual(card21?.address, "21, Winstanley Road, London SW11 2EZ")
        XCTAssertEqual(card21?.detailURLString,
            "https://www.rightmove.co.uk/house-prices/details/53cf973d-b694-4bab-85bd-7cc56644df77")
        // Every card carries a details link.
        XCTAssertTrue(cards.allSatisfy { $0.detailURLString.contains("/house-prices/details/") })
    }

    // MARK: - Matching

    func testMatchExactNumberAndStreet() throws {
        let cards = HousePricesLink.parseCards(html: try fixture("house-prices-sw11-2ez"))
        let match = HousePricesLink.matchCard(cards, to: "21 Winstanley Road")
        XCTAssertEqual(match?.detailURLString,
            "https://www.rightmove.co.uk/house-prices/details/53cf973d-b694-4bab-85bd-7cc56644df77")
    }

    func testMatchToleratesFlatPrefixAndPostcode() throws {
        let cards = HousePricesLink.parseCards(html: try fixture("house-prices-sw11-2ez"))
        let match = HousePricesLink.matchCard(cards, to: "Flat 2, 7 Winstanley Road, SW11 2EZ")
        XCTAssertEqual(match?.address, "7, Winstanley Road, London SW11 2EZ")
    }

    func testDoesNotConfuseNumber1WithNumber21() throws {
        // Substring matching would wrongly pair "1" into "21 Winstanley Road";
        // token-based PAON matching must keep them distinct.
        let cards = HousePricesLink.parseCards(html: try fixture("house-prices-sw11-2ez"))
        let match = HousePricesLink.matchCard(cards, to: "1 Winstanley Road")
        XCTAssertEqual(match?.address, "1, Winstanley Road, London SW11 2EZ")
    }

    func testNoMatchForDifferentStreet() throws {
        let cards = HousePricesLink.parseCards(html: try fixture("house-prices-sw11-2ez"))
        XCTAssertNil(HousePricesLink.matchCard(cards, to: "21 Acre Lane"))
        XCTAssertNil(HousePricesLink.matchCard(cards, to: "999 Winstanley Road"))
    }

    func testPaonAndStreetParsing() {
        let parsed = HousePricesLink.paonAndStreet("21, Winstanley Road, London SW11 2EZ")
        XCTAssertEqual(parsed?.paon, "21")
        XCTAssertEqual(parsed?.street, "Winstanley Road")
    }
}
