import SwiftUI
import SwiftData
import RightmoveKit
import PropertyStore

struct WatchlistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \PinnedProperty.pinnedAt, order: .reverse) private var pins: [PinnedProperty]

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(pins, id: \.propertyID) { pin in
                    NavigationLink(value: pin.propertyID) {
                        PropertyCard(
                            data: pin,
                            isPinned: true,
                            onTogglePin: { unpin(pin) }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
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

    private func unpin(_ pin: PinnedProperty) {
        TrackingStore(context: context).unpin(id: pin.propertyID)
    }
}
