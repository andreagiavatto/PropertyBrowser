import Foundation

/// Pure helpers for building Google Street View / Maps links and geocode
/// queries. No CoreLocation dependency so it unit-tests offline.
public enum StreetViewLink {

    /// A Street View panorama dropped at exact coordinates — lands on the
    /// frontage rather than a map pin.
    public static func pano(lat: Double, lng: Double) -> URL? {
        URL(string: "https://maps.google.com/maps?q=&layer=c&cbll=\(lat),\(lng)")
    }

    /// Fallback when geocoding fails: a Maps search for the address text. Drops
    /// the user at the place, from which Street View is one click away.
    public static func search(address: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed
        let q = address.addingPercentEncoding(withAllowedCharacters: allowed) ?? address
        return URL(string: "https://www.google.com/maps/search/?api=1&query=\(q)")
    }

    /// The query string to hand `CLGeocoder`: address + postcode + country,
    /// skipping any empty parts.
    public static func geocodeQuery(address: String, postcode: String?) -> String {
        [address, postcode, "UK"]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
