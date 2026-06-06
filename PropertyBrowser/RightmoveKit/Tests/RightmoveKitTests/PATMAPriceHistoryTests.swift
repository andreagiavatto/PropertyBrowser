import XCTest
import Foundation
@testable import RightmoveKit

final class PATMAPriceHistoryTests: XCTestCase {

    /// Trimmed but faithful copy of a real PaTMa panel: a Price History table
    /// followed by the gated Rent/Yield/ROI/Invest table that must be ignored.
    private let panelHTML = """
    <div>
      <h4>Price History</h4>
      <table>
        <tr>
          <td>6 Jun 2026</td>
          <td>&pound;600,000</td>
          <td>&rarr;</td>
          <td>&pound;575,000</td>
        </tr>
        <tr>
          <td>16 Apr 2026</td>
          <td>First seen</td>
          <td>&rarr;</td>
          <td>&pound;600,000</td>
        </tr>
      </table>
      <table>
        <tr><td>Rent</td><td>Yield</td><td>ROI</td><td>Invest</td></tr>
        <tr><td colspan="4"><a href="#">Create a FREE PaTMa account</a> to see these numbers.</td></tr>
      </table>
    </div>
    """

    func testParsesPriceHistoryRows() {
        let entries = PATMAPriceHistoryParser.parse(html: panelHTML)
        XCTAssertEqual(entries.count, 2, "Should ignore the gated Rent/Yield table")

        // Newest first, matching PaTMa's ordering.
        let reduction = entries[0]
        XCTAssertEqual(reduction.fromAmount, 600_000)
        XCTAssertEqual(reduction.toAmount, 575_000)
        XCTAssertFalse(reduction.isFirstSeen)
        XCTAssertEqual(reduction.delta, -25_000)

        let firstSeen = entries[1]
        XCTAssertTrue(firstSeen.isFirstSeen)
        XCTAssertNil(firstSeen.fromAmount)
        XCTAssertEqual(firstSeen.toAmount, 600_000)
        XCTAssertNil(firstSeen.delta)
    }

    func testParsesDates() {
        let entries = PATMAPriceHistoryParser.parse(html: panelHTML)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let comps = cal.dateComponents([.year, .month, .day], from: entries[0].date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 6)
    }

    func testDecodesEnvelopeAndParses() throws {
        // The endpoint returns { "html": "<...>" }.
        let payload = try JSONEncoder().encode(["html": panelHTML])
        let entries = try PATMAPriceHistoryParser.parse(responseData: payload)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.toAmount, 575_000)
    }

    func testEmptyForUnrelatedHTML() {
        XCTAssertTrue(PATMAPriceHistoryParser.parse(html: "<div>no tables here</div>").isEmpty)
    }
}
