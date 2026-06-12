import XCTest
@testable import RightmoveKit

final class StreetViewLinkTests: XCTestCase {

    func testPanoURL() {
        let url = StreetViewLink.pano(lat: 51.4571, lng: -0.1231)
        XCTAssertEqual(url?.absoluteString,
                       "https://maps.google.com/maps?q=&layer=c&cbll=51.4571,-0.1231")
    }

    func testSearchURLPercentEncodesAddress() {
        let url = StreetViewLink.search(address: "10, Acre Lane, London SW2 5SG")
        let s = try! XCTUnwrap(url?.absoluteString)
        XCTAssertTrue(s.hasPrefix("https://www.google.com/maps/search/?api=1&query="))
        XCTAssertFalse(s.contains(" "))          // spaces encoded
        XCTAssertTrue(s.contains("Acre") && s.contains("Lane"))
    }

    func testGeocodeQueryJoinsParts() {
        XCTAssertEqual(
            StreetViewLink.geocodeQuery(address: "10, Acre Lane, London", postcode: "SW2 5SG"),
            "10, Acre Lane, London, SW2 5SG, UK")
    }

    func testGeocodeQuerySkipsEmptyPostcode() {
        XCTAssertEqual(
            StreetViewLink.geocodeQuery(address: "10, Acre Lane", postcode: nil),
            "10, Acre Lane, UK")
        XCTAssertEqual(
            StreetViewLink.geocodeQuery(address: "10, Acre Lane", postcode: "  "),
            "10, Acre Lane, UK")
    }
}
