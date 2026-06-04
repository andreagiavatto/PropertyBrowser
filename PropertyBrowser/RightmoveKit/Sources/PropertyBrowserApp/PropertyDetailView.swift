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

    // New state
    @StateObject private var stationService = StationProximityService()
    @State private var floorArea: FloorArea?
    @State private var isLoadingFloorArea = false
    @State private var renderedDescription: AttributedString?
    @State private var descriptionExpanded = false

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
        .navigationTitle(Format.oneLine(detail?.address?.displayAddress))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: togglePin) {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin")
                }
            }
        }
        .task(id: propertyID) { await load() }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ d: PropertyDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // 1. Gallery
                gallery(d)

                // 2. Price + reduction badge + status
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.prices?.primaryPrice ?? "Price on application")
                            .font(.largeTitle.bold())
                        if let q = d.prices?.displayPriceQualifier, !q.isEmpty {
                            Text(q).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(state: d.listingState)
                    }
                    if let badge = reductionBadge {
                        Text(badge)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    // 3. Address
                    Text(Format.oneLine(d.address?.displayAddress))
                        .font(.title3).foregroundStyle(.secondary)

                    // 4. Facts row
                    factsRow(d)
                }

                // 5. Verdict checklist
                verdictChecklist(d)

                // 6. Floorplan
                if let floor = d.floorplans?.first?.url, let url = URL(string: floor) {
                    section("Floorplan") {
                        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) }
                            placeholder: { ProgressView() }
                            .frame(maxHeight: 420)
                    }
                }

                // 7 + 8. Map with station pins + nearest stations list
                if let lat = d.location?.lat, let lng = d.location?.lng {
                    section("Location") {
                        stationMap(lat: lat, lng: lng, title: Format.oneLine(d.address?.displayAddress))
                    }
                    if !stationService.stations.isEmpty || stationService.isLoading {
                        section("Nearest stations") { stationList() }
                    }
                }

                // 9. Listing age + update reason
                listingAgeLine(d)

                // 10. Price history chart
                if isPinned, let pin { priceHistory(pin) }

                // 11. Key features
                if let features = d.keyFeatures, !features.isEmpty {
                    section("Key features") {
                        ForEach(features, id: \.self) { f in
                            Label(f, systemImage: "checkmark.circle").font(.callout)
                        }
                    }
                }

                // 12. Description (HTML, collapsed)
                if renderedDescription != nil || d.text?.description?.isEmpty == false {
                    descriptionSection(d)
                }

                // 13. Lease / service charge
                leaseSection(d)

                // 14. View on Rightmove
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

    // MARK: - Gallery

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

    // MARK: - Facts row

    @ViewBuilder
    private func factsRow(_ d: PropertyDetail) -> some View {
        HStack(spacing: 18) {
            if let beds = d.bedrooms?.int   { Label("\(beds) bed",   systemImage: "bed.double") }
            if let baths = d.bathrooms?.int  { Label("\(baths) bath", systemImage: "shower") }
            if let type = d.propertySubType  { Label(type,            systemImage: "house") }
            if let tenure = d.tenure?.tenureType { Label(tenure.capitalized, systemImage: "doc.text") }
            if isLoadingFloorArea {
                Label("Calculating area…", systemImage: "ruler")
                    .redacted(reason: .placeholder)
            } else if let area = floorArea {
                Label(area.formatted, systemImage: "ruler")
                if let price = pin?.currentPriceAmount ?? d.prices?.parsedAmount,
                   area.sqm > 0 {
                    let ppm2 = Int((Double(price) / area.sqm).rounded())
                    Label("£\(Format.thousands(ppm2))/m²", systemImage: "sterlingsign.square")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - Verdict checklist

    @ViewBuilder
    private func verdictChecklist(_ d: PropertyDetail) -> some View {
        let hasFloorplan    = !(d.floorplans ?? []).isEmpty
        let hasArea         = floorArea != nil && floorArea?.isApproximate == false
        let stationNearby   = stationService.stations.first?.isWithin500m == true

        HStack(spacing: 16) {
            VerdictDot(label: "Floorplan",   met: hasFloorplan)
            VerdictDot(label: "Area known",  met: hasArea)
            VerdictDot(label: "Station ≤500m", met: stationNearby,
                       loading: stationService.isLoading && stationService.stations.isEmpty)
        }
        .font(.footnote)
    }

    // MARK: - Map + station overlays

    @ViewBuilder
    private func stationMap(lat: Double, lng: Double, title: String) -> some View {
        let propertyCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        Map(initialPosition: .region(MKCoordinateRegion(
            center: propertyCoord,
            latitudinalMeters: 1400,
            longitudinalMeters: 1400
        ))) {
            // Property marker
            Marker(title, coordinate: propertyCoord)
                .tint(.red)

            // Walk-distance lines (separate ForEach — @MapContentBuilder
            // can't mix Marker + MapPolyline in the same iteration)
            ForEach(stationService.stations) { station in
                MapPolyline(coordinates: [propertyCoord, station.coordinate])
                    .stroke(.blue.opacity(0.55), lineWidth: 2)
            }

            // Station markers — label shows walking time · distance once resolved
            ForEach(stationService.stations) { station in
                Marker(
                    stationMarkerLabel(station),
                    systemImage: "tram.fill",
                    coordinate: station.coordinate
                )
                .tint(.blue)
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            if stationService.isLoading && stationService.stations.isEmpty {
                ProgressView()
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
    }

    /// Pin label: station name, plus "time · distance" once the walk is resolved.
    private func stationMarkerLabel(_ station: NearbyStation) -> String {
        if let info = station.formattedDistanceAndDuration {
            return "\(station.name)\n\(info)"
        }
        return station.name
    }

    // MARK: - Station list

    @ViewBuilder
    private func stationList() -> some View {
        VStack(spacing: 6) {
            ForEach(stationService.stations) { station in
                HStack {
                    Image(systemName: "tram.fill").foregroundStyle(.blue)
                    Text(station.name).font(.callout)
                    Spacer()
                    if let info = station.formattedDistanceAndDuration {
                        Text(info)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }
        }
    }

    // MARK: - Listing age

    @ViewBuilder
    private func listingAgeLine(_ d: PropertyDetail) -> some View {
        if let date = d.listingAddedDate {
            let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
            let ageText: String = {
                if days == 0 { return "Added today" }
                if days == 1 { return "Added yesterday" }
                return "Added \(days) days ago"
            }()
            // Only append the update reason when it's a change (Reduced / Increased),
            // not when it just repeats "Added on …".
            let verb = d.listingHistory?.verb?.lowercased() ?? ""
            let showUpdate = !verb.isEmpty && verb != "added"
            let updateText = showUpdate ? (d.listingHistory?.listingUpdateReason.map { " · \($0)" } ?? "") : ""
            Text(ageText + updateText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Description (HTML, collapsed)

    @ViewBuilder
    private func descriptionSection(_ d: PropertyDetail) -> some View {
        section("Description") {
            if let attr = renderedDescription {
                VStack(alignment: .leading, spacing: 6) {
                    Text(attr)
                        .font(.callout)
                        .lineLimit(descriptionExpanded ? nil : 5)
                        .textSelection(.enabled)
                    Button(descriptionExpanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            descriptionExpanded.toggle()
                        }
                    }
                    .font(.callout)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            } else if let raw = d.text?.description, !raw.isEmpty {
                // Fallback while attributed string is being built (or if it fails)
                Text(raw)
                    .font(.callout)
                    .lineLimit(descriptionExpanded ? nil : 5)
                    .textSelection(.enabled)
                Button(descriptionExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        descriptionExpanded.toggle()
                    }
                }
                .font(.callout)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Lease / service charge

    @ViewBuilder
    private func leaseSection(_ d: PropertyDetail) -> some View {
        let leaseTerms = (d.keyFeatures ?? []).filter { feature in
            let lower = feature.lowercased()
            return lower.contains("lease") || lower.contains("ground rent")
                || lower.contains("service charge") || lower.contains("maintenance")
        }
        if !leaseTerms.isEmpty {
            section("Lease & charges") {
                ForEach(leaseTerms, id: \.self) { term in
                    Label(term, systemImage: "doc.plaintext").font(.callout)
                }
            }
        }
    }

    // MARK: - Price history

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

    // MARK: - Price reduction badge

    private var reductionBadge: String? {
        guard let pin else { return nil }
        let reductions = pin.events.filter { $0.isPriceReduction }
        guard !reductions.isEmpty else { return nil }
        let firstPrice = pin.events
            .filter { $0.kind == .firstSeen || $0.kind == .priceChange }
            .sorted { $0.date < $1.date }
            .first?.toAmount
        let currentPrice = pin.currentPriceAmount
        var totalDrop = ""
        if let first = firstPrice, let current = currentPrice, first > current {
            totalDrop = " −£\(Format.thousands(first - current))"
        }
        let count = reductions.count
        return "Reduced \(count)×\(totalDrop)"
    }

    // MARK: - Section helper

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    // MARK: - Data helpers

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

    // MARK: - Load

    private func load() async {
        isLoading = true
        error = nil
        detail = nil
        floorArea = nil
        renderedDescription = nil

        do {
            let d = try await model.client.fetchPropertyDetail(id: propertyID)
            detail = d
            isLoading = false   // Show the page immediately

            if isPinned, let snap = TrackedSnapshot(detail: d) {
                TrackingStore(context: context).apply(snap)
            }

            // HTML description: synchronous on MainActor, fast
            if let html = d.text?.description, !html.isEmpty {
                renderedDescription = html.htmlToAttributedString()
            }

            // Floor area + station search: run concurrently
            isLoadingFloorArea = true
            let floorURL = d.floorplans?.first?.url.flatMap(URL.init(string:))
            let price    = d.prices?.parsedAmount
            let ppsf     = d.prices?.pricePerSqFt

            if let lat = d.location?.lat, let lng = d.location?.lng {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                async let areaResult  = FloorplanAnalyser.extract(
                    floorplanURL: floorURL,
                    totalPriceGBP: price,
                    pricePerSqFtString: ppsf
                )
                async let stationTask: Void = stationService.load(near: coord)
                let (area, _) = await (areaResult, stationTask)
                floorArea = area
            } else {
                floorArea = await FloorplanAnalyser.extract(
                    floorplanURL: floorURL,
                    totalPriceGBP: price,
                    pricePerSqFtString: ppsf
                )
            }
            isLoadingFloorArea = false

        } catch {
            self.error = "\(error)"
            isLoading = false
            isLoadingFloorArea = false
        }
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

// MARK: - Verdict dot

private struct VerdictDot: View {
    let label: String
    let met: Bool
    var loading: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if loading {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            } else {
                Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(met ? .green : .secondary)
            }
            Text(label)
        }
    }
}

// MARK: - Helpers

extension String {
    /// Convert an HTML string to an AttributedString using AppKit.
    /// Must be called on the main thread.
    @MainActor
    func htmlToAttributedString() -> AttributedString? {
        guard let data = data(using: .utf8) else { return nil }
        guard let ns = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else { return nil }
        return try? AttributedString(ns, including: \.appKit)
    }
}

extension DetailPrices {
    /// Parse the primary price string into an Int amount.
    var parsedAmount: Int? {
        guard let s = primaryPrice else { return nil }
        let digits = s.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}


