import SwiftUI
import SwiftData
import MapKit
import Charts
import RightmoveKit
import PropertyStore

struct PropertyDetailView: View {
    let propertyID: Int

    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query private var pins: [PinnedProperty]

    @State private var detail: PropertyDetail?
    @State private var isLoading = true
    @State private var error: String?

    private var pin: PinnedProperty? { pins.first { $0.propertyID == propertyID } }
    private var isPinned: Bool { pin != nil }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading listing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Couldn't load this listing",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error ?? "Unknown error")
                )
            }
        }
        .navigationTitle(Format.oneLine(detail?.address?.displayAddress) )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: togglePin) {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin")
                }
            }
        }
        .task(id: propertyID) { await load() }
    }

    @ViewBuilder
    private func content(_ d: PropertyDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                gallery(d)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.prices?.primaryPrice ?? "Price on application")
                            .font(.largeTitle.bold())
                        if let q = d.prices?.displayPriceQualifier, !q.isEmpty {
                            Text(q).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(state: d.listingState)
                    }
                    Text(Format.oneLine(d.address?.displayAddress))
                        .font(.title3).foregroundStyle(.secondary)
                    factsRow(d)
                }

                if isPinned, let pin { priceHistory(pin) }

                if let features = d.keyFeatures, !features.isEmpty {
                    section("Key features") {
                        ForEach(features, id: \.self) { f in
                            Label(f, systemImage: "checkmark.circle").font(.callout)
                        }
                    }
                }

                if let desc = d.text?.description, !desc.isEmpty {
                    section("Description") {
                        Text(desc).font(.callout).textSelection(.enabled)
                    }
                }

                if let lat = d.location?.lat, let lng = d.location?.lng {
                    section("Location") { mapView(lat: lat, lng: lng, title: Format.oneLine(d.address?.displayAddress)) }
                }

                if let floor = d.floorplans?.first?.url, let url = URL(string: floor) {
                    section("Floorplan") {
                        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) }
                            placeholder: { ProgressView() }
                            .frame(maxHeight: 420)
                    }
                }

                if let url = rightmoveURL(forID: propertyID) {
                    Link(destination: url) {
                        Label("View on Rightmove", systemImage: "safari")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func gallery(_ d: PropertyDetail) -> some View {
        let urls = (d.images ?? []).compactMap { $0.galleryURLString.flatMap(URL.init(string:)) }
        if urls.isEmpty {
            RoundedRectangle(cornerRadius: 10).fill(.gray.opacity(0.15))
                .frame(height: 320)
                .overlay { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) }
                            placeholder: { Color.gray.opacity(0.12) }
                            .frame(width: 480, height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(height: 320)
        }
    }

    @ViewBuilder
    private func factsRow(_ d: PropertyDetail) -> some View {
        HStack(spacing: 18) {
            if let beds = d.bedrooms?.int { Label("\(beds) bed", systemImage: "bed.double") }
            if let baths = d.bathrooms?.int { Label("\(baths) bath", systemImage: "shower") }
            if let type = d.propertySubType { Label(type, systemImage: "house") }
            if let tenure = d.tenure?.tenureType { Label(tenure.capitalized, systemImage: "doc.text") }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func priceHistory(_ pin: PinnedProperty) -> some View {
        let points = pricePoints(pin)
        if points.count >= 2 {
            section("Price history") {
                Chart(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Price", p.amount))
                        .interpolationMethod(.stepEnd)
                    PointMark(x: .value("Date", p.date), y: .value("Price", p.amount))
                }
                .frame(height: 200)
            }
        }
    }

    @ViewBuilder
    private func mapView(lat: Double, lng: Double, title: String) -> some View {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))) {
            Marker(title, coordinate: coord)
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    // MARK: Data

    private struct PricePoint: Identifiable {
        let id = UUID()
        let date: Date
        let amount: Int
    }

    private func pricePoints(_ pin: PinnedProperty) -> [PricePoint] {
        pin.events
            .filter { $0.kind == .firstSeen || $0.kind == .priceChange }
            .sorted { $0.date < $1.date }
            .compactMap { e in (e.toAmount).map { PricePoint(date: e.date, amount: $0) } }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            detail = try await model.client.fetchPropertyDetail(id: propertyID)
            // If pinned, fold this fresh fetch into the history.
            if isPinned, let d = detail, let snap = TrackedSnapshot(detail: d) {
                TrackingStore(context: context).apply(snap)
            }
        } catch {
            self.error = "\(error)"
            detail = nil
        }
        isLoading = false
    }

    private func togglePin() {
        let store = TrackingStore(context: context)
        if store.isPinned(id: propertyID) {
            store.unpin(id: propertyID)
        } else if let d = detail, let snap = TrackedSnapshot(detail: d) {
            store.pin(snap)
        }
    }
}
