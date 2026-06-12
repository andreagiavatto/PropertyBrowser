import XCTest
@testable import RightmoveKit

final class EPCMatcherTests: XCTestCase {

    // MARK: - Street parsing

    func testParsesPlainStreet() {
        XCTAssertEqual(StreetName.parse(from: "Acre Lane, London"), "Acre Lane")
    }

    func testSkipsLeadingFlatSegment() {
        XCTAssertEqual(StreetName.parse(from: "Flat 2, Acre Lane, London"), "Acre Lane")
    }

    func testStripsInlineFlatPrefix() {
        XCTAssertEqual(StreetName.parse(from: "Flat 2 Acre Lane, London"), "Acre Lane")
    }

    func testStripsLeadingHouseNumber() {
        XCTAssertEqual(StreetName.parse(from: "12 Acre Lane, London SW2"), "Acre Lane")
    }

    func testKeepsMultiWordStreet() {
        XCTAssertEqual(StreetName.parse(from: "Brixton Hill, London SW2"), "Brixton Hill")
    }

    func testApartmentWithLetterSkipped() {
        XCTAssertEqual(StreetName.parse(from: "Apartment 5B, High Street, Leeds"), "High Street")
    }

    func testNilAndEmpty() {
        XCTAssertNil(StreetName.parse(from: nil))
        XCTAssertNil(StreetName.parse(from: "   "))
    }

    // MARK: - Street comparison

    func testAddressIsOnStreetExact() {
        XCTAssertTrue(StreetName.address("10, Acre Lane, London", isOn: "Acre Lane"))
    }

    func testAddressIsOnStreetAbbreviated() {
        // EPC abbreviates "Lane" → "Ln"; the listing spells it out.
        XCTAssertTrue(StreetName.address("10 Acre Ln London", isOn: "Acre Lane"))
    }

    func testAddressNotOnDifferentStreet() {
        XCTAssertFalse(StreetName.address("1, Brixton Hill, London", isOn: "Acre Lane"))
    }

    // MARK: - Dedupe

    func testLatestCertificatePerAddressWins() {
        let old = cert("10, Acre Lane, London", area: 80, date: "2018-01-01")
        let new = cert("10, Acre Lane, London", area: 84, date: "2023-01-01")
        let result = EPCMatcher.latestPerAddress([old, new])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.totalFloorArea, 84)
    }

    // MARK: - Room score

    func testRoomScoreBands() {
        XCTAssertEqual(EPCMatcher.roomScore(bedrooms: 3, habitableRooms: 5), 1.0)  // +2
        XCTAssertEqual(EPCMatcher.roomScore(bedrooms: 3, habitableRooms: 3), 1.0)  // +0
        XCTAssertEqual(EPCMatcher.roomScore(bedrooms: 3, habitableRooms: 7), 0.5)  // +4
        XCTAssertEqual(EPCMatcher.roomScore(bedrooms: 3, habitableRooms: 9), 0.0)  // +6
    }

    // MARK: - Ranking end to end

    func testRankPicksClosestAreaOnStreet() {
        let certs = [
            cert("10, Acre Lane, London", area: 84,  type: "House", form: "Mid-Terrace", rooms: 4),
            cert("12, Acre Lane, London", area: 102, type: "House", form: "End-Terrace", rooms: 5),
            cert("14, Acre Lane, London", area: 120, type: "House", form: "Detached",    rooms: 6),
            cert("1, Brixton Hill, London", area: 85, type: "House", form: "Mid-Terrace", rooms: 4),
        ]
        let ranked = EPCMatcher.rank(
            certificates: certs,
            street: "Acre Lane",
            floorAreaSqm: 85,
            bedrooms: 3,
            propertySubType: "Terraced")

        // Off-street dropped; 102 and 120 m² exceed ±10% of 85 and are dropped.
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.certificate.address, "10, Acre Lane, London")
        XCTAssertGreaterThan(ranked.first?.score ?? 0, 0.8)
        XCTAssertFalse(ranked.first?.matchedSignals.isEmpty ?? true)
    }

    func testRankDropsOutOfToleranceArea() {
        let certs = [cert("12, Acre Lane, London", area: 102, rooms: 5)]
        let ranked = EPCMatcher.rank(
            certificates: certs, street: "Acre Lane",
            floorAreaSqm: 85, bedrooms: 3, propertySubType: nil)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testRankWithoutAreaKeepsCandidatesAndRanksOnTypeRooms() {
        let certs = [
            cert("10, Acre Lane, London", type: "House", form: "Mid-Terrace", rooms: 5),
            cert("14, Acre Lane, London", type: "Flat",  form: "",            rooms: 2),
        ]
        let ranked = EPCMatcher.rank(
            certificates: certs, street: "Acre Lane",
            floorAreaSqm: nil, bedrooms: 3, propertySubType: "Terraced House")

        XCTAssertEqual(ranked.count, 2)
        // The terraced house should outrank the flat.
        XCTAssertEqual(ranked.first?.certificate.address, "10, Acre Lane, London")
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testStreetFilterExcludesOtherStreets() {
        let certs = [
            cert("1, Brixton Hill, London", area: 85, rooms: 4),
            cert("99, Other Road, London",  area: 85, rooms: 4),
        ]
        let ranked = EPCMatcher.rank(
            certificates: certs, street: "Brixton Hill",
            floorAreaSqm: 85, bedrooms: 3, propertySubType: nil)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.certificate.address, "1, Brixton Hill, London")
    }

    // MARK: - Outcode filtering

    func testOutcodeExtraction() {
        XCTAssertEqual(EPCMatcher.outcode(of: "N14 5AB"), "N14")
        XCTAssertEqual(EPCMatcher.outcode(of: "sw2 5sg"), "SW2")
        // API sometimes returns a '+' in place of the space.
        XCTAssertEqual(EPCMatcher.outcode(of: "M20+4AP"), "M20")
        XCTAssertNil(EPCMatcher.outcode(of: "X"))
        XCTAssertNil(EPCMatcher.outcode(of: nil))
    }

    func testRankFiltersByOutcode() {
        // Same street name, two different outcodes — only the listing's should rank.
        let here  = cert("9 Union Street, Manchester", area: 85, rooms: 4, postcode: "M20 4AP")
        let other = cert("9 Union Street, Leeds",      area: 85, rooms: 4, postcode: "LS1 5AB")
        let ranked = EPCMatcher.rank(
            certificates: [here, other], street: "Union Street",
            floorAreaSqm: 85, bedrooms: 3, propertySubType: nil, outcode: "M20")
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.certificate.postcode, "M20 4AP")
    }

    // MARK: - Shortlist (search summaries → detail candidates)

    func testShortlistFiltersOutcodeStreetAndDedupes() {
        let results = [
            // On-street, in-outcode; two certs for the same address → keep latest.
            summary("0001", "10, Acre Lane, London", "SW2 5SG", "2019-01-01"),
            summary("0002", "10, Acre Lane, London", "SW2 5SG", "2023-01-01"),
            // On-street but wrong outcode → dropped.
            summary("0003", "10, Acre Lane, Leeds", "LS1 4AA", "2024-01-01"),
            // In-outcode but different street → dropped.
            summary("0004", "1, Brixton Hill, London", "SW2 1RW", "2022-01-01"),
        ]
        let short = EPCMatcher.shortlist(results, street: "Acre Lane", outcode: "SW2")
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short.first?.certificateNumber, "0002") // the newer one
    }

    // MARK: - Helpers

    private func summary(_ rrn: String, _ address: String, _ postcode: String,
                         _ date: String) -> EPCSearchResult {
        EPCSearchResult(certificateNumber: rrn, address: address, postcode: postcode,
                        registrationDate: Self.day(date))
    }

    private func cert(_ address: String, area: Double? = nil, type: String? = nil,
                      form: String? = nil, rooms: Int? = nil, date: String = "2022-01-01",
                      postcode: String? = nil)
        -> EPCCertificate {
        EPCCertificate(
            address: address, postcode: postcode, propertyType: type, builtForm: form,
            totalFloorArea: area, habitableRooms: rooms,
            lodgementDate: Self.day(date), uprn: nil)
    }

    private static func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? .distantPast
    }
}
