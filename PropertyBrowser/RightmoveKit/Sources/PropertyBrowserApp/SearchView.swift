import SwiftUI
import SwiftData
import RightmoveKit
import PropertyStore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query private var pins: [PinnedProperty]

    private var pinnedIDs: Set<Int> { Set(pins.map(\.propertyID)) }

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Paste a Rightmove search URL…", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.runSearch() } }
                Button {
                    Task { await model.runSearch() }
                } label: {
                    if model.isSearching { ProgressView().controlSize(.small) }
                    else { Text("Search") }
                }
                .disabled(model.isSearching || model.searchText.isEmpty)
            }
            .padding()

            if let error = model.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if let count = model.resultCount {
                Text("\(count) results — showing \(model.results.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            List(model.results, id: \.propertyID) { property in
                if let id = property.propertyID {
                    NavigationLink(value: id) {
                        SearchResultRow(
                            property: property,
                            isPinned: pinnedIDs.contains(id),
                            onTogglePin: { togglePin(property) }
                        )
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.results.isEmpty && !model.isSearching {
                    ContentUnavailableView(
                        "No results",
                        systemImage: "magnifyingglass",
                        description: Text("Paste a Rightmove results URL above to browse listings.")
                    )
                }
            }
        }
        .navigationTitle("Search")
    }

    private func togglePin(_ property: SearchProperty) {
        guard let id = property.propertyID else { return }
        let store = TrackingStore(context: context)
        if store.isPinned(id: id) {
            store.unpin(id: id)
        } else if let snapshot = TrackedSnapshot(search: property) {
            store.pin(snapshot, sourceSearchURL: model.searchText)
        }
    }
}

struct SearchResultRow: View {
    let property: SearchProperty
    let isPinned: Bool
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(property.price?.primaryDisplay ?? "Price on application")
                    .font(.headline)
                Text(Format.oneLine(property.displayAddress))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    StatusBadge(state: property.listingState)
                    if let beds = property.bedrooms?.int {
                        Label("\(beds)", systemImage: "bed.double").font(.caption)
                    }
                    if let reason = property.listingUpdate?.listingUpdateReason, reason == "price_reduced" {
                        Label("Reduced", systemImage: "arrow.down.right")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
            Spacer()
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "Unpin" : "Pin to watchlist")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var thumbnail: some View {
        if let urlString = property.propertyImages?.images?.first?.srcUrl,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.gray.opacity(0.15)
            }
            .frame(width: 96, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 96, height: 72)
                .overlay { Image(systemName: "house").foregroundStyle(.secondary) }
        }
    }
}
