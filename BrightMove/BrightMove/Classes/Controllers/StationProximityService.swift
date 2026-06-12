import Combine
import MapKit
import CoreLocation
import SwiftUI
import RightmoveKit

// MARK: - Transport type presentation

extension TransportType {
    /// SF Symbol used for this mode in lists and on the map.
    public var systemImageName: String {
        switch self {
        case .underground: return "tram.tunnel.fill"
        case .rail:        return "train.side.front.car"
        case .lightRail:   return "tram"
        case .tram:        return "tram.fill"
        case .bus:         return "bus.fill"
        case .ferry:       return "ferry.fill"
        case .other:       return "mappin.and.ellipse"
        }
    }

    /// Tint used for this mode's icon and map marker.
    public var tint: Color {
        switch self {
        case .underground: return .red
        case .rail:        return .blue
        case .lightRail:   return .teal
        case .tram:        return .green
        case .bus:         return .orange
        case .ferry:       return .cyan
        case .other:       return .gray
        }
    }
}

// MARK: - Model

public struct NearbyStation: Identifiable {
    public let id = UUID()
    /// The mode of transport (bus, rail, underground, …), for distinct icons.
    public let type: TransportType
    public let name: String
    public let coordinate: CLLocationCoordinate2D
    /// Walking distance in metres. nil while loading; uses straight-line as fallback.
    public var walkingMetres: Double?
    /// Estimated walking time in seconds. nil while loading.
    public var walkingSeconds: Double?
    /// True when walkingMetres is a straight-line estimate rather than a routed distance.
    public var isApproximate: Bool = false

    public var formattedDistance: String? {
        guard let m = walkingMetres else { return nil }
        let prefix = isApproximate ? "~" : ""
        if m < 1000 {
            return "\(prefix)\(Int(m.rounded()))m"
        } else {
            return String(format: "\(prefix)%.1f km", m / 1000)
        }
    }

    /// Walking time, e.g. "6 min" or "<1 min". nil while loading.
    public var formattedDuration: String? {
        guard let s = walkingSeconds else { return nil }
        let prefix = isApproximate ? "~" : ""
        let minutes = Int((s / 60).rounded())
        return minutes < 1 ? "\(prefix)<1 min" : "\(prefix)\(minutes) min"
    }

    /// Combined label for a map pin, e.g. "6 min · 450m". nil while loading.
    public var formattedDistanceAndDuration: String? {
        switch (formattedDuration, formattedDistance) {
        case let (dur?, dist?): return "\(dur) · \(dist)"
        case let (dur?, nil):   return dur
        case let (nil, dist?):  return dist
        default:                return nil
        }
    }

    /// True when the station is within 500 m walking distance.
    public var isWithin500m: Bool {
        guard let m = walkingMetres else { return false }
        return m <= 500
    }
}

// MARK: - Service

/// Finds the nearest public-transport stops via the Overpass API (so each is
/// classified by mode) and resolves walking distances with MKDirections (one
/// request per stop, up to maxResults).
@MainActor
public final class StationProximityService: ObservableObject {

    @Published public var stations: [NearbyStation] = []
    @Published public var isLoading = false

    /// Total stops shown, and the most bus stops among them. Buses are capped so
    /// that — in dense cities where stops sit on every corner — they don't crowd
    /// out the rail/Tube stations that matter more for a property. Tunable.
    private let maxResults = 6
    private let maxBusStops = 2
    private let radiusMetres: Double = 1000
    private let overpass = OverpassClient()

    public func load(near coordinate: CLLocationCoordinate2D) async {
        isLoading = true
        stations = []

        let found = await searchStations(near: coordinate)
        // Seed with stations, distances nil (spinner per row).
        stations = found
        isLoading = false

        // Resolve walking distances concurrently.
        await withTaskGroup(of: (Int, Double, Double, Bool).self) { group in
            for (idx, station) in found.enumerated() {
                group.addTask {
                    let (metres, seconds, approx) = await Self.walkingDistance(
                        from: coordinate,
                        to: station.coordinate
                    )
                    return (idx, metres, seconds, approx)
                }
            }
            for await (idx, metres, seconds, approx) in group {
                if idx < stations.count {
                    stations[idx].walkingMetres = metres
                    stations[idx].walkingSeconds = seconds
                    stations[idx].isApproximate = approx
                }
            }
        }
    }

    // MARK: - Overpass search

    private func searchStations(near coordinate: CLLocationCoordinate2D) async -> [NearbyStation] {
        guard let stops = try? await overpass.fetchStops(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMetres: radiusMetres
        ) else { return [] }

        let propertyLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // Nearest first by straight-line distance; MKDirections refines later.
        let sorted = stops.sorted { a, b in
            propertyLoc.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                < propertyLoc.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }

        // De-duplicate repeated names of the same mode (e.g. a station mapped as
        // several nodes), then take the nearest few while capping bus stops.
        var seen = Set<String>()
        var picked: [NearbyStation] = []
        var busCount = 0
        for stop in sorted {
            let key = "\(stop.name)|\(stop.type.rawValue)"
            guard !seen.contains(key) else { continue }
            if stop.type == .bus {
                guard busCount < maxBusStops else { continue }
                busCount += 1
            }
            seen.insert(key)
            picked.append(NearbyStation(
                type: stop.type,
                name: stop.name,
                coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
            ))
            if picked.count >= maxResults { break }
        }
        return picked
    }

    // MARK: - MKDirections

    /// Returns (distanceMetres, durationSeconds, isApproximate).
    private static func walkingDistance(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> (Double, Double, Bool) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .walking

        if let response = try? await MKDirections(request: request).calculate(),
           let route = response.routes.first {
            return (route.distance, route.expectedTravelTime, false)
        }
        // Fallback: haversine straight-line distance, time at ~1.4 m/s walking pace.
        let metres = haversine(from: origin, to: destination)
        return (metres, metres / 1.4, true)
    }

    // MARK: - Haversine

    private static func haversine(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let R = 6_371_000.0 // Earth radius in metres
        let φ1 = a.latitude  * .pi / 180
        let φ2 = b.latitude  * .pi / 180
        let Δφ = (b.latitude  - a.latitude)  * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let x = sin(Δφ/2) * sin(Δφ/2)
              + cos(φ1) * cos(φ2) * sin(Δλ/2) * sin(Δλ/2)
        return R * 2 * atan2(sqrt(x), sqrt(1 - x))
    }
}
