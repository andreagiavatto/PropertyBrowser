import XCTest
@testable import RightmoveKit

final class LandRegistryClientTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture \(name).json")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    func testParsesRecordsAndSkipsIncomplete() throws {
        let records = try LandRegistryClient.parse(data: fixtureData("landregistry-sw2"))
        // The last binding has no price and must be dropped.
        XCTAssertEqual(records.count, 4)
    }

    func testDecodesFieldsAndDerivesYear() throws {
        let records = try LandRegistryClient.parse(data: fixtureData("landregistry-sw2"))
        XCTAssertEqual(records[0].paon, "10")
        XCTAssertEqual(records[0].street, "ACRE LANE")
        XCTAssertEqual(records[0].price, 166000)
        XCTAssertEqual(records[0].year, 2000)
        XCTAssertEqual(records[1].price, 550000)
        XCTAssertEqual(records[1].year, 2016)
        XCTAssertEqual(records[3].saon, "FLAT 2")
        XCTAssertEqual(records[3].paon, "5")
    }

    func testPostcodeNormalisation() {
        XCTAssertEqual(LandRegistryClient.normalisePostcode("sw25sg"), "SW2 5SG")
        XCTAssertEqual(LandRegistryClient.normalisePostcode("SW2  5SG"), "SW2 5SG")
        XCTAssertEqual(LandRegistryClient.normalisePostcode("n14 5ab"), "N14 5AB")
    }

    func testSparqlContainsNormalisedPostcode() {
        let q = LandRegistryClient.sparql(postcode: "sw2 5sg")
        XCTAssertTrue(q.contains("\"SW2 5SG\""))
        XCTAssertTrue(q.contains("lrppi:pricePaid"))
    }
}
