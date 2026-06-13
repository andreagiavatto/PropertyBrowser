import XCTest
@testable import RightmoveKit

final class LandCValuationClientTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture \(name).json")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Response parsing

    func testParsesValueAndRentFromFixture() throws {
        let v = try LandCValuationClient.valuation(from: fixtureData("landc-houseprice"), source: "L&C")
        XCTAssertEqual(v.source, "L&C")
        XCTAssertEqual(v.value, MoneyRange(lower: 296000, mid: 366177, upper: 437000))
        XCTAssertEqual(v.rent, MoneyRange(lower: 1230, mid: 1520, upper: 1810))
    }

    func testZeroedResultIsNoEstimate() throws {
        let json = Data(#"{"result":{"PropertyValue":0,"ValuationUpper":0,"ValuationLower":0}}"#.utf8)
        XCTAssertThrowsError(try LandCValuationClient.valuation(from: json, source: "L&C")) {
            XCTAssertEqual($0 as? ValuationError, .noEstimate)
        }
    }

    func testMissingResultIsNoEstimate() throws {
        let json = Data(#"{"url":"x","body":"y"}"#.utf8)
        XCTAssertThrowsError(try LandCValuationClient.valuation(from: json, source: "L&C")) {
            XCTAssertEqual($0 as? ValuationError, .noEstimate)
        }
    }

    func testValueWithoutRentStillParses() throws {
        let json = Data(#"{"result":{"PropertyValue":300000,"ValuationUpper":330000,"ValuationLower":270000}}"#.utf8)
        let v = try LandCValuationClient.valuation(from: json, source: "L&C")
        XCTAssertEqual(v.value.mid, 300000)
        XCTAssertNil(v.rent)
    }

    func testGarbageBodyIsNetworkError() {
        let json = Data("not json".utf8)
        XCTAssertThrowsError(try LandCValuationClient.valuation(from: json, source: "L&C")) {
            guard case .network = ($0 as? ValuationError) else {
                return XCTFail("expected .network, got \($0)")
            }
        }
    }

    // MARK: - House-number extraction

    func testBuildingNumberFromVariousShapes() {
        XCTAssertEqual(ValuationAddress.buildingNumber(from: "15, Felmersham Close, SW4 7EU"), "15")
        XCTAssertEqual(ValuationAddress.buildingNumber(from: "12 Acre Lane, London"), "12")
        XCTAssertEqual(ValuationAddress.buildingNumber(from: "Flat 2, 12 Acre Lane"), "12")
        XCTAssertEqual(ValuationAddress.buildingNumber(from: "12A Acre Lane"), "12A")
        XCTAssertNil(ValuationAddress.buildingNumber(from: "Acre Lane, London"))
        XCTAssertNil(ValuationAddress.buildingNumber(from: ""))
        XCTAssertNil(ValuationAddress.buildingNumber(from: nil))
    }

    // MARK: - Flat / sub-building extraction

    func testSubBuildingNameFromVariousShapes() {
        XCTAssertEqual(ValuationAddress.subBuildingName(from: "Flat C, 52 Dukes Avenue, N10 2PU"), "Flat C")
        XCTAssertEqual(ValuationAddress.subBuildingName(from: "Apartment 5B, 12 Acre Lane"), "Apartment 5B")
        XCTAssertEqual(ValuationAddress.subBuildingName(from: "Flat C 52 Dukes Avenue"), "Flat C")
        XCTAssertEqual(ValuationAddress.subBuildingName(from: "Penthouse, 1 High Road"), "Penthouse")
        XCTAssertNil(ValuationAddress.subBuildingName(from: "52 Dukes Avenue, London"))
        XCTAssertNil(ValuationAddress.subBuildingName(from: "Flatford Road, London")) // not a unit
    }

    // MARK: - Query construction

    func testQueryFromResolvedAddressSplitsFields() {
        let q = ValuationQuery(resolvedAddress: "15, Felmersham Close, London", postcode: "SW4 7EU")
        XCTAssertEqual(q.buildingNumber, "15")
        XCTAssertNil(q.subBuildingName)
        XCTAssertEqual(q.street, "Felmersham Close")
        XCTAssertEqual(q.postcode, "SW4 7EU")
    }

    func testQueryFromFlatAddressSplitsNumberAndFlat() {
        let q = ValuationQuery(resolvedAddress: "Flat C, 52 Dukes Avenue, London", postcode: "N10 2PU")
        XCTAssertEqual(q.buildingNumber, "52")
        XCTAssertEqual(q.subBuildingName, "Flat C")
        XCTAssertEqual(q.street, "Dukes Avenue")
        XCTAssertEqual(q.postcode, "N10 2PU")
    }

    // MARK: - Request encoding

    private func decodeBody(_ data: Data) throws -> [String: String] {
        struct Body: Decodable { let input: [String: String] }
        return try JSONDecoder().decode(Body.self, from: data).input
    }

    func testHouseRequestOmitsSubBuildingName() throws {
        let data = try LandCValuationClient.requestBody(
            number: "15", flat: nil, street: "Felmersham Close", postcode: "SW4 7EU")
        let input = try decodeBody(data)
        XCTAssertEqual(input["Number"], "15")
        XCTAssertEqual(input["Street"], "Felmersham Close")
        XCTAssertEqual(input["Postcode"], "SW4 7EU")
        XCTAssertNil(input["SubBuildingName"])
    }

    func testFlatRequestIncludesBothNumberAndSubBuildingName() throws {
        let data = try LandCValuationClient.requestBody(
            number: "52", flat: "Flat C", street: "Dukes Avenue", postcode: "n10 2pu")
        let input = try decodeBody(data)
        XCTAssertEqual(input["Number"], "52")
        XCTAssertEqual(input["SubBuildingName"], "Flat C")
        XCTAssertEqual(input["Street"], "Dukes Avenue")
        XCTAssertEqual(input["Postcode"], "n10 2pu")
    }

    func testEstimateThrowsInsufficientInputWithFlatButNoStreet() async {
        let client = LandCValuationClient()
        let q = ValuationQuery(buildingNumber: nil, subBuildingName: "Flat C",
                               street: nil, postcode: "N10 2PU")
        do {
            _ = try await client.estimate(for: q)
            XCTFail("expected insufficientInput")
        } catch {
            XCTAssertEqual(error as? ValuationError, .insufficientInput)
        }
    }

    // MARK: - Input validation

    func testEstimateThrowsInsufficientInputWhenIncomplete() async {
        let client = LandCValuationClient()
        let q = ValuationQuery(buildingNumber: nil, street: "Acre Lane", postcode: "SW2 1AA")
        do {
            _ = try await client.estimate(for: q)
            XCTFail("expected insufficientInput")
        } catch {
            XCTAssertEqual(error as? ValuationError, .insufficientInput)
        }
    }
}
