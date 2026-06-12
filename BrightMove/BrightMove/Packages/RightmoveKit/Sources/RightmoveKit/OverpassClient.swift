import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The mode of a nearby public-transport stop, classified from OpenStreetMap
/// tags. Unlike Apple's single `.publicTransport` POI category, this lets the
/// UI tell a bus stop apart from a Tube station.
public enum TransportType: String, Sendable, CaseIterable, Codable {
    case underground   // London Underground / metro / subway
    case rail          // National Rail, Overground, Elizabeth line, etc.
    case lightRail     // DLR and other light-rail / metro-lite
    case tram          // street trams
    case bus           // bus stops
    case ferry         // ferry / river-bus terminals
    case other

    public var label: String {
        switch self {
        case .underground: return "Underground"
        case .rail:        return "Rail"
        case .lightRail:   return "Light rail"
        case .tram:        return "Tram"
        case .bus:         return "Bus"
        case .ferry:       return "Ferry"
        case .other:       return "Transport"
        }
    }

    /// True for fixed-rail/ferry stations (i.e. not a bus stop). Used where the
    /// distinction matters, like the "Station ≤500m" verdict, which shouldn't be
    /// satisfied by a bus stop.
    public var isStation: Bool {
        switch self {
        case .bus, .other: return false
        default:           return true
        }
    }
}

/// A single public-transport stop returned by the Overpass API.
public struct OverpassStop: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let type: TransportType

    public init(id: Int, name: String, latitude: Double, longitude: Double, type: TransportType) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.type = type
    }
}

public enum OverpassError: Error, CustomStringConvertible {
    case badURL
    case notHTTP
    case httpError(statusCode: Int)

    public var description: String {
        switch self {
        case .badURL:                return "Could not build the Overpass request URL"
        case .notHTTP:               return "Overpass response was not an HTTP response"
        case .httpError(let status): return "Overpass HTTP error \(status)"
        }
    }
}

/// Queries the free, key-less Overpass API (OpenStreetMap) for public-transport
/// stops around a coordinate, classifying each by mode. Coverage and fair-use
/// limits come from the public Overpass instances; results should be cached by
/// the caller and a descriptive `User-Agent` is sent to stay within policy.
public struct OverpassClient: Sendable {

    /// Default public endpoint. Swap for a self-hosted/mirror instance if needed.
    public static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    private let endpoint: URL
    private let session: URLSession
    private let userAgent: String

    public init(
        endpoint: URL = OverpassClient.defaultEndpoint,
        session: URLSession = .shared,
        userAgent: String = "BrightMove/1.0 (property transport lookup)"
    ) {
        self.endpoint = endpoint
        self.session = session
        self.userAgent = userAgent
    }

    /// Fetch nearby stops within `radiusMetres` of the coordinate.
    public func fetchStops(
        latitude: Double,
        longitude: Double,
        radiusMetres: Double = 1000
    ) async throws -> [OverpassStop] {
        let query = Self.query(latitude: latitude, longitude: longitude, radiusMetres: radiusMetres)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Overpass expects the QL in a `data` form field.
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OverpassError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw OverpassError.httpError(statusCode: http.statusCode)
        }
        return Self.parse(data)
    }

    // MARK: - Query

    /// Builds the Overpass QL for the transport modes we classify. Bus stops are
    /// nodes; stations may be nodes, ways or relations, so `out center tags`
    /// yields a representative coordinate for non-node elements.
    static func query(latitude: Double, longitude: Double, radiusMetres: Double) -> String {
        let lat = String(format: "%.6f", latitude)
        let lon = String(format: "%.6f", longitude)
        let r = String(format: "%.0f", radiusMetres)
        let around = "(around:\(r),\(lat),\(lon))"
        return """
        [out:json][timeout:25];
        (
          node["highway"="bus_stop"]\(around);
          node["railway"="tram_stop"]\(around);
          nwr["railway"="station"]\(around);
          nwr["public_transport"="station"]\(around);
          nwr["amenity"="ferry_terminal"]\(around);
        );
        out center tags;
        """
    }

    // MARK: - Parsing (testable, no network)

    /// Decode an Overpass JSON payload into classified, named stops. Unnamed
    /// elements and ones we can't classify are dropped.
    static func parse(_ data: Data) -> [OverpassStop] {
        guard let response = try? JSONDecoder().decode(OverpassResponse.self, from: data) else {
            return []
        }
        return response.elements.compactMap { element in
            guard let name = element.tags?["name"], !name.isEmpty,
                  let type = classify(tags: element.tags ?? [:]),
                  let lat = element.lat ?? element.center?.lat,
                  let lon = element.lon ?? element.center?.lon else { return nil }
            return OverpassStop(id: element.id, name: name, latitude: lat, longitude: lon, type: type)
        }
    }

    /// Map a stop's OSM tags to a `TransportType`, or `nil` if it isn't one of
    /// the stop kinds we surface.
    static func classify(tags: [String: String]) -> TransportType? {
        if tags["highway"] == "bus_stop" { return .bus }
        if tags["railway"] == "tram_stop" { return .tram }
        if tags["amenity"] == "ferry_terminal" { return .ferry }

        let isStation = tags["railway"] == "station" || tags["public_transport"] == "station"
        if isStation {
            // `station` (or legacy `subway`/`light_rail` flags) refines the mode.
            switch tags["station"] {
            case "subway":     return .underground
            case "light_rail": return .lightRail
            default: break
            }
            if tags["subway"] == "yes"     { return .underground }
            if tags["light_rail"] == "yes" { return .lightRail }
            if tags["tram"] == "yes"       { return .tram }
            return .rail
        }
        return nil
    }

    // MARK: - Wire format

    private struct OverpassResponse: Decodable {
        let elements: [Element]
    }

    private struct Element: Decodable {
        let id: Int
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?
    }

    private struct Center: Decodable {
        let lat: Double
        let lon: Double
    }
}
