import XCTest
@testable import RightmoveKit

final class SoldHistoryClientTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture \(name).json")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    func testParsesAllTransactions() throws {
        let h = try SoldHistoryClient.parse(data: fixtureData("sold-history"))
        XCTAssertEqual(h.soldPropertyTransactions.count, 6)
        XCTAssertEqual(h.soldPropertyUrlPath, "/house-prices/details/c39de1da-978a-4a48-801e-57cb186a972d")
    }

    func testParsesYearAndPriceFromDisplayStrings() throws {
        let txns = try SoldHistoryClient.parse(data: fixtureData("sold-history")).soldPropertyTransactions
        XCTAssertEqual(txns[0].year, 2016)
        XCTAssertEqual(txns[0].price, 550000)
        XCTAssertEqual(txns[1].price, 312500)
        XCTAssertEqual(txns[2].price, 269950)
    }

    func testLastSoldIsMostRecentYear() throws {
        let h = try SoldHistoryClient.parse(data: fixtureData("sold-history"))
        XCTAssertEqual(h.lastSold?.year, 2016)
        XCTAssertEqual(h.lastSold?.price, 550000)
    }

    func testPriceParsingEdgeCases() {
        XCTAssertEqual(SoldTransaction.parsePrice("£550,000"), 550000)
        XCTAssertEqual(SoldTransaction.parsePrice("1,234"), 1234)
        XCTAssertNil(SoldTransaction.parsePrice("POA"))
        XCTAssertNil(SoldTransaction.parsePrice(""))
    }
}
