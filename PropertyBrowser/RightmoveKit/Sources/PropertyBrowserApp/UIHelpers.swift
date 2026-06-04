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
