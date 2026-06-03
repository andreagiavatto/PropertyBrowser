import SwiftUI
import SwiftData
import RightmoveKit
import PropertyStore

struct WatchlistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \PinnedProperty.pinnedAt, order: .reverse) private var pins: [PinnedProperty]

    var body: some View {
        List {
            ForEach(pins, id: \.propertyID) { pin in
                NavigationLink(value: pin.propertyID) {
                    WatchlistRow(pin: pin)
                }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.inset)
        .overlay {
            if pins.isEmpty {
                ContentUnavailableView(
                    "No pinned properties",
                    systemImage: "pin",
                    description: Text("Pin properties from a search to track their price and status over time.")
                )
            }
        }
        .navigationTitle("Watchlist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    else { Label("Refresh now", systemImage: "arrow.clockwise") }
                }
                .disabled(model.isRefreshing || pins.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let summary = model.lastRefreshSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let store = TrackingStore(context: context)
        for index in offsets { store.unpin(id: pins[index].propertyID) }
    }
}

struct WatchlistRow: View {
    let pin: PinnedProperty

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pin.currentPriceDisplay ?? "—").font(.headline)
                Spacer()
                StatusBadge(state: pin.currentState)
            }
            Text(Format.oneLine(pin.displayAddress))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text("Checked \(Format.relative(pin.lastCheckedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
