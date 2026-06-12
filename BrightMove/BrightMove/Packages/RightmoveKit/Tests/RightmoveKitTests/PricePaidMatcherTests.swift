import XCTest
@testable import RightmoveKit

final class PricePaidMatcherTests: XCTestCase {

    private static func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? .distantPast
    }

    private func ppd(_ paon: String?, _ price: Int, _ date: String,
                     saon: String? = nil, street: String? = "ACRE LANE") -> PricePaidRecord {
        PricePaidRecord(paon: paon, saon: saon, street: street, postcode: "SW2 5SG",
                        price: price, date: Self.day(date))
    }

    private func sold(_ year: Int, _ price: Int) -> SoldTransaction {
        SoldTransaction(year: year, price: price)
    }

    func testIdentifiesAddressByMultipleMatchingSales() {
        // Listing sold 2016 £550k and 2000 £166k → that's number 10.
        let history = [sold(2016, 550000), sold(2000, 166000)]
        let txns = [
            ppd("10", 166000, "2000-06-30"),
            ppd("10", 550000, "2016-09-15"),
            ppd("12", 615000, "2018-02-01"),
            ppd("5", 300000, "2019-11-20", saon: "FLAT 2", street: "BRIXTON HILL"),
        ]
        let best = PricePaidMatcher.bestMatch(soldHistory: history, transactions: txns)
        XCTAssertEqual(best?.paon, "10")
        XCTAssertEqual(best?.matchedTransactions, 2)
        XCTAssertEqual(best?.lastSoldPrice, 550000)
        XCTAssertEqual(best?.lastSoldYear, 2016)
    }

    func testRanksAllMatchingAddresses() {
        let history = [sold(2016, 550000), sold(2018, 615000)]
        let txns = [
            ppd("10", 550000, "2016-09-15"),
            ppd("12", 615000, "2018-02-01"),
        ]
        let ranked = PricePaidMatcher.identify(soldHistory: history, transactions: txns)
        XCTAssertEqual(ranked.count, 2) // both match one sale each
        XCTAssertEqual(ranked.allSatisfy { $0.matchedTransactions == 1 }, true)
    }

    func testAmbiguousSingleSaleTieReturnsNil() {
        // Two addresses each match the one sale → not confident.
        let history = [sold(2016, 550000)]
        let txns = [
            ppd("10", 550000, "2016-09-15"),
            ppd("12", 550000, "2016-10-01"),
        ]
        XCTAssertNil(PricePaidMatcher.bestMatch(soldHistory: history, transactions: txns))
        XCTAssertEqual(PricePaidMatcher.identify(soldHistory: history, transactions: txns).count, 2)
    }

    func testSingleAddressSingleSaleIsConfident() {
        let history = [sold(2016, 550000)]
        let txns = [
            ppd("10", 550000, "2016-09-15"),
            ppd("12", 615000, "2018-02-01"), // doesn't match the sold price
        ]
        XCTAssertEqual(PricePaidMatcher.bestMatch(soldHistory: history, transactions: txns)?.paon, "10")
    }

    func testNoMatchReturnsNil() {
        let history = [sold(2016, 999999)]
        let txns = [ppd("10", 550000, "2016-09-15")]
        XCTAssertNil(PricePaidMatcher.bestMatch(soldHistory: history, transactions: txns))
        XCTAssertTrue(PricePaidMatcher.identify(soldHistory: history, transactions: txns).isEmpty)
    }

    func testFlatDistinguishedBySaon() {
        let history = [sold(2019, 300000)]
        let txns = [
            ppd("5", 300000, "2019-11-20", saon: "FLAT 2", street: "BRIXTON HILL"),
            ppd("5", 280000, "2019-05-01", saon: "FLAT 1", street: "BRIXTON HILL"),
        ]
        let best = PricePaidMatcher.bestMatch(soldHistory: history, transactions: txns)
        XCTAssertEqual(best?.saon, "FLAT 2")
        XCTAssertEqual(best?.civicLabel, "FLAT 2, 5")
    }
}
