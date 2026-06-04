import Foundation
import MapKit
import CoreLocation

// MARK: - Model

struct NearbyStation: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
    let name: String
    let coordinate: CLLocationCoordinate2D
    /// Walking distance in metres. nil while loading; uses straight-line as fallback.
    var walkingMetres: Double?
    /// Estimated walking time in seconds. nil while loading.
    var walkingSeconds: Double?
    /// True when walkingMetres is a straight-line estimate rather than a routed distance.
    var isApproximate: Bool = false

    var formattedDistance: String? {
        guard let m = walkingMetres else { return nil }
        let prefix = isApproximate ? "~" : ""
        if m < 1000 {
            return "\(prefix)\(Int(m.rounded()))m"
        } else {
            return String(format: "\(prefix)%.1f km", m / 1000)
        }
    }

    /// Walking time, e.g. "6 min" or "<1 min". nil while loading.
    var formattedDuration: String? {
        guard let s = walkingSeconds else { return nil }
        let prefix = isApproximate ? "~" : ""
        let minutes = Int((s / 60).rounded())
        return minutes < 1 ? "\(prefix)<1 min" : "\(prefix)\(minutes) min"
    }

    /// Combined label for a map pin, e.g. "6 min · 450m". nil while loading.
    var formattedDistanceAndDuration: String? {
        switch (formattedDuration, formattedDistance) {
        case let (dur?, dist?): return "\(dur) · \(dist)"
        case let (dur?, nil):   return dur
        case let (nil, dist?):  return dist
        default:                return nil
        }
    }

    /// True when the station is within 500 m walking distance.
    var isWithin500m: Bool {
        guard let m = walkingMetres else { return false }
        return m <= 500
    }
}

// MARK: - Service

/// Finds the nearest stations via MKLocalSearch and resolves walking distances
/// with MKDirections (one request per station, up to maxResults).
@MainActor
final class StationProximityService: ObservableObject {

    @Published var stations: [NearbyStation] = []
    @Published var isLoading = false

    private let maxResults = 3
    private let radiusMetres: Double = 1000

    func load(near coordinate: CLLocationCoordinate2D) async {
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

    // MARK: - MKLocalSearch

    private func searchStations(near coordinate: CLLocationCoordinate2D) async -> [NearbyStation] {
        // Category-based POI search around a coordinate. A plain
        // MKLocalSearch.Request needs a naturalLanguageQuery to return results;
        // MKLocalPointsOfInterestRequest is the correct API for searching by
        // POI category within a radius.
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radiusMetres)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])

        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }

        return response.mapItems
            .filter { item in
                guard let loc = item.placemark.location else { return false }
                let propertyLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                return loc.distance(from: propertyLoc) <= radiusMetres
            }
            .sorted { a, b in
                let propLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let dA = a.placemark.location?.distance(from: propLoc) ?? .greatestFiniteMagnitude
                let dB = b.placemark.location?.distance(from: propLoc) ?? .greatestFiniteMagnitude
                return dA < dB
            }
            .prefix(maxResults)
            .compactMap { item -> NearbyStation? in
                guard let name = item.name,
                      let loc = item.placemark.location else { return nil }
                return NearbyStation(
                    mapItem: item,
                    name: name,
                    coordinate: loc.coordinate
                )
            }
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
