import SwiftUI
import RightmoveKit
import PropertyStore

// MARK: - Status badge

struct StatusBadge: View {
    let state: ListingState

    var body: some View {
        Text(state.displayLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .available: return .green
        case .underOffer: return .orange
        case .soldSTC: return .red
        case .delisted: return .secondary
        case .unknown: return .gray
        }
    }
}

// MARK: - Helpers

enum Format {
    static func oneLine(_ s: String?) -> String {
        (s ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func thousands(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

extension ListingState {
    /// Convenience to pull a state straight from a stored raw string.
    static func from(raw: String) -> ListingState { ListingState(rawValue: raw) ?? .unknown }

    var displayLabel: String {
        switch self {
        case .available: return "Available"
        case .underOffer: return "Under Offer"
        case .soldSTC: return "Sold STC"
        case .delisted: return "Delisted"
        case .unknown: return "Unknown"
        }
    }
}

/// Builds the full property URL from a search row's relative `propertyUrl`.
func rightmoveURL(forID id: Int) -> URL? {
    URL(string: "https://www.rightmove.co.uk/properties/\(id)")
}

/// Inverse of `rightmoveURL(forID:)`: pulls the numeric property ID out of a
/// pasted Rightmove listing URL.
///
/// Accepts the canonical `rightmove.co.uk/properties/{id}` shape, tolerant of a
/// missing scheme, trailing `#/?channel=…` fragments, query params, trailing
/// slashes, and surrounding whitespace. Returns nil for anything that isn't a
/// Rightmove property link.
func rightmovePropertyID(from raw: String) -> Int? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // URLComponents needs a scheme to parse the host reliably.
    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: withScheme),
          let host = components.host?.lowercased(),
          host == "rightmove.co.uk" || host.hasSuffix(".rightmove.co.uk")
    else { return nil }

    // Find the path segment immediately after "properties" and read its leading
    // digits (the fragment/query are already split off by URLComponents).
    let segments = components.path.split(separator: "/").map(String.init)
    guard let idx = segments.firstIndex(where: { $0.lowercased() == "properties" }),
          idx + 1 < segments.count
    else { return nil }

    let digits = segments[idx + 1].prefix { $0.isNumber }
    guard !digits.isEmpty, let id = Int(digits) else { return nil }
    return id
}
