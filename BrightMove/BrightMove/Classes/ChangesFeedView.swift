import SwiftUI
import SwiftData
import RightmoveKit
import PropertyStore

struct ChangesFeedView: View {
    @Query(sort: \PropertyEvent.date, order: .reverse) private var events: [PropertyEvent]

    var body: some View {
        List(events, id: \.persistentModelID) { event in
            NavigationLink(value: event.property?.propertyID ?? -1) {
                ChangeRow(event: event)
            }
            .disabled(event.property == nil)
        }
        .listStyle(.inset)
        .overlay {
            if events.isEmpty {
                ContentUnavailableView(
                    "No changes yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Price and status changes to your pinned properties will appear here after a refresh.")
                )
            }
        }
        .navigationTitle("Changes")
    }
}

struct ChangeRow: View {
    let event: PropertyEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.oneLine(event.property?.displayAddress) )
                    .font(.subheadline).lineLimit(1)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.relative(event.date)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch event.kind {
        case .firstSeen: return "plus.circle"
        case .priceChange: return event.isPriceReduction ? "arrow.down.right.circle" : "arrow.up.right.circle"
        case .statusChange: return "tag.circle"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .firstSeen: return .blue
        case .priceChange: return event.isPriceReduction ? .green : .orange
        case .statusChange: return .purple
        }
    }

    private var detail: String {
        switch event.kind {
        case .firstSeen:
            return "Pinned at \(event.toDisplay ?? "—")"
        case .priceChange:
            return "\(event.fromDisplay ?? "—") → \(event.toDisplay ?? "—")"
        case .statusChange:
            let from = event.fromState?.displayLabel ?? "—"
            let to = event.toState?.displayLabel ?? "—"
            return "\(from) → \(to)"
        }
    }
}
