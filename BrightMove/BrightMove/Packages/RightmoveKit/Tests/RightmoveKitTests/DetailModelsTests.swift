import XCTest
@testable import RightmoveKit

final class DetailModelsTests: XCTestCase {

    /// A minimal slice of `propertyData` exercising the fields the civic-number
    /// cross-check depends on (mirrors the real page model shape).
    private let json = """
    {
      "id": 89316741,
      "encId": "WqjmsT2-9L3w2c2rxO90Uj21dKBRM7V0P0T-Ig==",
      "address": {
        "displayAddress": "Nightingale Lane, London, N8",
        "outcode": "N8",
        "incode": "7RA",
        "deliveryPointId": 2044055
      }
    }
    """

    func testDecodesEncIdAndDeliveryPointId() throws {
        let detail = try JSONDecoder().decode(PropertyDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.encId, "WqjmsT2-9L3w2c2rxO90Uj21dKBRM7V0P0T-Ig==")
        XCTAssertEqual(detail.address?.deliveryPointId?.int, 2044055)
    }

    func testFullPostcodeJoinsOutcodeAndIncode() throws {
        let detail = try JSONDecoder().decode(PropertyDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.address?.fullPostcode, "N8 7RA")
    }

    func testFullPostcodeNilWhenIncodeMissing() throws {
        let detail = try JSONDecoder().decode(
            PropertyDetail.self,
            from: Data(#"{"id": 1, "address": {"outcode": "N8"}}"#.utf8))
        XCTAssertNil(detail.address?.fullPostcode)
    }

    // MARK: - Floor area from sizings

    private func detail(sizingsJSON: String) throws -> PropertyDetail {
        try JSONDecoder().decode(
            PropertyDetail.self,
            from: Data(#"{"id": 1, "sizings": \#(sizingsJSON)}"#.utf8))
    }

    func testFloorAreaPrefersSquareMetres() throws {
        // Both units present: the sqm figure is used directly (no conversion),
        // even though the sqft figure is listed first.
        let d = try detail(sizingsJSON: """
        [
          {"unit": "sqft", "minimumSize": 915, "maximumSize": 915},
          {"unit": "sqm", "minimumSize": 85, "maximumSize": 85}
        ]
        """)
        XCTAssertEqual(try XCTUnwrap(d.floorAreaSqM), 85, accuracy: 0.001)
    }

    func testFloorAreaConvertsSquareFeetWhenNoMetres() throws {
        let d = try detail(sizingsJSON: #"[{"unit": "sqft", "minimumSize": 1000, "maximumSize": 1000}]"#)
        // 1000 sq ft × 0.092903 = 92.903 m²
        XCTAssertEqual(try XCTUnwrap(d.floorAreaSqM), 92.903, accuracy: 0.001)
    }

    func testFloorAreaNilWhenNoSizings() throws {
        let d = try JSONDecoder().decode(PropertyDetail.self, from: Data(#"{"id": 1}"#.utf8))
        XCTAssertNil(d.floorAreaSqM)
    }

    func testFloorAreaNilWhenSizesAreZero() throws {
        let d = try detail(sizingsJSON: """
        [
          {"unit": "sqft", "minimumSize": 0, "maximumSize": 0},
          {"unit": "sqm", "minimumSize": 0, "maximumSize": 0}
        ]
        """)
        XCTAssertNil(d.floorAreaSqM)
    }

    func testFloorAreaFallsBackToMaximumWhenMinimumMissing() throws {
        let d = try detail(sizingsJSON: #"[{"unit": "sqm", "maximumSize": 120}]"#)
        XCTAssertEqual(try XCTUnwrap(d.floorAreaSqM), 120, accuracy: 0.001)
    }

    /// Real `sizings` payloads also carry land units (hectares, acres) with zero
    /// values for a flat. The square-metre figure must still be picked, and the
    /// land entries ignored. Shape taken verbatim from a live Rightmove page.
    func testFloorAreaIgnoresLandUnits() throws {
        let d = try detail(sizingsJSON: """
        [
          {"unit": "sqm", "displayUnit": "sq. m.", "minimumSize": 50, "maximumSize": 50},
          {"unit": "ha", "displayUnit": "ha.", "minimumSize": 0, "maximumSize": 0},
          {"unit": "ac", "displayUnit": "ac.", "minimumSize": 0.01, "maximumSize": 0.01},
          {"unit": "sqft", "displayUnit": "sq. ft.", "minimumSize": 538, "maximumSize": 538}
        ]
        """)
        XCTAssertEqual(try XCTUnwrap(d.floorAreaSqM), 50, accuracy: 0.001)
    }
}
