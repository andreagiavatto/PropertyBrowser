import XCTest
import Foundation
@testable import RightmoveKit

final class EPCClientTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture \(name).json")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Search summary parsing

    func testParsesAllSearchRows() throws {
        let page = try EPCClient.parseSearch(data: fixtureData("epc-sw2"))
        XCTAssertEqual(page.data.count, 3)
    }

    func testJoinsMultiLineAddress() throws {
        let rows = try EPCClient.parseSearch(data: fixtureData("epc-sw2")).data
        XCTAssertEqual(rows[0].address, "10, Acre Lane, London")
        XCTAssertEqual(rows[0].postcode, "SW2 5SG")
        XCTAssertEqual(rows[0].certificateNumber, "0001-2222-3333-4444-0001")
        XCTAssertEqual(rows[2].address, "Flat 2, 5 Brixton Hill, London")
    }

    func testDecodesNumericUPRNAsString() throws {
        let rows = try EPCClient.parseSearch(data: fixtureData("epc-sw2")).data
        XCTAssertEqual(rows[0].uprn, "100021468190")
        // Row 2 has no uprn field.
        XCTAssertNil(rows[2].uprn)
    }

    func testParsesRegistrationDateBareAndISO() throws {
        let rows = try EPCClient.parseSearch(data: fixtureData("epc-sw2")).data
        let cal = Calendar(identifier: .iso8601)
        let bare = cal.dateComponents(in: TimeZone(identifier: "UTC")!,
                                      from: try XCTUnwrap(rows[0].registrationDate))
        XCTAssertEqual(bare.year, 2021); XCTAssertEqual(bare.month, 3); XCTAssertEqual(bare.day, 11)
        let iso = cal.dateComponents(in: TimeZone(identifier: "UTC")!,
                                     from: try XCTUnwrap(rows[1].registrationDate))
        XCTAssertEqual(iso.year, 2023); XCTAssertEqual(iso.month, 8); XCTAssertEqual(iso.day, 2)
    }

    func testParsesPaginationCursor() throws {
        let page = try EPCClient.parseSearch(data: fixtureData("epc-sw2"))
        XCTAssertEqual(page.pagination?.totalRecords, 3)
        XCTAssertEqual(page.pagination?.currentPage, 1)
        XCTAssertNil(page.pagination?.nextPage) // last page stops the loop
    }

    func testParseSearchThrowsOnEmptyData() {
        XCTAssertThrowsError(try EPCClient.parseSearch(data: Data()))
    }

    // MARK: - Certificate detail parsing

    func testParsesDetailSnakeCaseFields() throws {
        let d = try EPCClient.parseDetail(data: fixtureData("epc-detail"))
        XCTAssertEqual(d.totalFloorArea, 84)
        XCTAssertEqual(d.dwellingType, "Mid-terrace house")
        XCTAssertEqual(d.habitableRoomCount, 4)
        XCTAssertEqual(d.registrationDate, "2021-03-11")
        XCTAssertEqual(d.uprn, 100021468190)
    }

    func testParsesDetailFromDataEnvelope() throws {
        // The API may wrap the document in { "data": { … } }.
        let bare = try fixtureData("epc-detail")
        let wrapped = try JSONSerialization.jsonObject(with: bare)
        let envelope = try JSONSerialization.data(withJSONObject: ["data": wrapped])
        let d = try EPCClient.parseDetail(data: envelope)
        XCTAssertEqual(d.totalFloorArea, 84)
        XCTAssertEqual(d.dwellingType, "Mid-terrace house")
    }

    // MARK: - UPRN normalisation

    func testUPRNIsLeftPaddedTo12Digits() {
        XCTAssertEqual(EPCClient.paddedUPRN("1234567"), "000001234567")
        XCTAssertEqual(EPCClient.paddedUPRN("100021468190"), "100021468190")
        XCTAssertEqual(EPCClient.paddedUPRN("  10 0021468190 "), "100021468190")
        XCTAssertNil(EPCClient.paddedUPRN("abc"))
    }
}
