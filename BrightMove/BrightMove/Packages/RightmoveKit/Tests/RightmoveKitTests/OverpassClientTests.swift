import XCTest
@testable import RightmoveKit

final class OverpassClientTests: XCTestCase {

    /// A faithful slice of an Overpass JSON response covering each mode plus a
    /// way (station mapped as an area, so coordinates arrive under `center`) and
    /// rows that must be dropped (no name, unclassifiable).
    private let json = """
    {
      "elements": [
        {"type":"node","id":1,"lat":51.6,"lon":-0.12,"tags":{"name":"Bounds Green","railway":"station","station":"subway"}},
        {"type":"node","id":2,"lat":51.601,"lon":-0.121,"tags":{"name":"Bowes Park","railway":"station"}},
        {"type":"node","id":3,"lat":51.602,"lon":-0.122,"tags":{"name":"High Rd / Sample St","highway":"bus_stop"}},
        {"type":"node","id":4,"lat":51.603,"lon":-0.123,"tags":{"name":"Pier Road","amenity":"ferry_terminal"}},
        {"type":"node","id":5,"lat":51.604,"lon":-0.124,"tags":{"name":"Croydon Tramlink","railway":"tram_stop"}},
        {"type":"node","id":6,"lat":51.605,"lon":-0.125,"tags":{"name":"Pudding Mill Lane","railway":"station","station":"light_rail"}},
        {"type":"way","id":7,"center":{"lat":51.606,"lon":-0.126},"tags":{"name":"Big Interchange","public_transport":"station","train":"yes"}},
        {"type":"node","id":8,"lat":51.607,"lon":-0.127,"tags":{"railway":"station"}},
        {"type":"node","id":9,"lat":51.608,"lon":-0.128,"tags":{"name":"A Cafe","amenity":"cafe"}}
      ]
    }
    """

    func testParsesAndClassifiesEachMode() throws {
        let stops = OverpassClient.parse(Data(json.utf8))
        let byName = Dictionary(uniqueKeysWithValues: stops.map { ($0.name, $0.type) })

        XCTAssertEqual(byName["Bounds Green"], .underground)
        XCTAssertEqual(byName["Bowes Park"], .rail)
        XCTAssertEqual(byName["High Rd / Sample St"], .bus)
        XCTAssertEqual(byName["Pier Road"], .ferry)
        XCTAssertEqual(byName["Croydon Tramlink"], .tram)
        XCTAssertEqual(byName["Pudding Mill Lane"], .lightRail)
        XCTAssertEqual(byName["Big Interchange"], .rail)
    }

    func testDropsUnnamedAndUnclassifiable() {
        let stops = OverpassClient.parse(Data(json.utf8))
        // id 8 (no name) and id 9 (a cafe) must not appear.
        XCTAssertEqual(stops.count, 7)
        XCTAssertFalse(stops.contains { $0.name == "A Cafe" })
    }

    func testWayUsesCenterCoordinates() throws {
        let stops = OverpassClient.parse(Data(json.utf8))
        let interchange = try XCTUnwrap(stops.first { $0.name == "Big Interchange" })
        XCTAssertEqual(interchange.latitude, 51.606, accuracy: 1e-6)
        XCTAssertEqual(interchange.longitude, -0.126, accuracy: 1e-6)
    }

    func testClassifyTagCombinations() {
        XCTAssertEqual(OverpassClient.classify(tags: ["highway": "bus_stop"]), .bus)
        XCTAssertEqual(OverpassClient.classify(tags: ["railway": "tram_stop"]), .tram)
        XCTAssertEqual(OverpassClient.classify(tags: ["amenity": "ferry_terminal"]), .ferry)
        XCTAssertEqual(OverpassClient.classify(tags: ["railway": "station"]), .rail)
        XCTAssertEqual(OverpassClient.classify(tags: ["railway": "station", "station": "subway"]), .underground)
        XCTAssertEqual(OverpassClient.classify(tags: ["public_transport": "station", "subway": "yes"]), .underground)
        XCTAssertNil(OverpassClient.classify(tags: ["amenity": "cafe"]))
    }

    func testTransportTypeIsStationExcludesBus() {
        XCTAssertFalse(TransportType.bus.isStation)
        XCTAssertFalse(TransportType.other.isStation)
        XCTAssertTrue(TransportType.rail.isStation)
        XCTAssertTrue(TransportType.underground.isStation)
        XCTAssertTrue(TransportType.tram.isStation)
        XCTAssertTrue(TransportType.ferry.isStation)
    }

    func testQueryIncludesRadiusAndCoordinate() {
        let q = OverpassClient.query(latitude: 51.5, longitude: -0.1, radiusMetres: 800)
        XCTAssertTrue(q.contains("around:800,51.500000,-0.100000"))
        XCTAssertTrue(q.contains(#"["highway"="bus_stop"]"#))
        XCTAssertTrue(q.contains("out center tags;"))
    }
}
