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
    @Query private var resolvedAddresses: [ResolvedAddress]

    @State private var detail: PropertyDetail?
    @State private var isLoading = true
    @State private var error: String?

    // Async-derived content
    @StateObject private var stationService = StationProximityService()
    @State private var floorArea: FloorArea?
    @State private var isLoadingFloorArea = false
    @State private var renderedDescription: AttributedString?

    // External (PaTMa) historical prices
    @State private var priceHistory: [PriceHistoryEntry] = []
    @State private var isLoadingPriceHistory = false

    // Floorplan zoom viewer
    @State private var showFloorplanViewer = false
    @State private var floorplanStartIndex = 0

    // Address resolution (EPC + Street View)
    @State private var isResolving = false
    @State private var resolveOutcome: ResolveOutcome?

    // Land Registry civic-number cross-check (runs on candidate selection)
    @State private var isCrossChecking = false
    @State private var civicMatch: CivicNumberLookup.Result?

    // Collapsible-section state, remembered app-wide (essentials stay expanded;
    // these four start collapsed).
    @AppStorage("detail.section.description") private var descriptionExpanded = false
    @AppStorage("detail.section.features")    private var featuresExpanded = false
    @AppStorage("detail.section.lease")       private var leaseExpanded = false
    @AppStorage("detail.section.history")     private var historyExpanded = false

    /// Optional PaTMa `sessionid` cookie (only unlocks gated Rent/Yield figures;
    /// price history is returned without it). Set in Settings.
    @AppStorage("patma.sessionid") private var patmaSessionID = ""

    /// Width at which the layout splits into two columns.
    private let twoColumnBreakpoint: CGFloat = 900

    private var pin: PinnedProperty? { pins.first { $0.propertyID == propertyID } }
    private var isPinned: Bool { pin != nil }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading listing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail {
                responsiveContent(detail)
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
            if let url = rightmoveURL(forID: propertyID) {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url, subject: Text(Format.oneLine(detail?.address?.displayAddress))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: togglePin) {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin")
                }
                .foregroundStyle(isPinned ? .purple : .primary)
            }
        }
        .task(id: propertyID) { await load() }
    }

    // MARK: - Responsive container

    @ViewBuilder
    private func responsiveContent(_ d: PropertyDetail) -> some View {
        GeometryReader { geo in
            if geo.size.width >= twoColumnBreakpoint {
                // Two columns: sticky media on the left, scrolling details on the right.
                let mediaWidth = min(480, geo.size.width * 0.44)
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        mediaColumn(d).padding(24)
                    }
                    .frame(minWidth: mediaWidth)

                    ScrollView {
                        detailsColumn(d)
                            .padding(24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Single stacked column; uses the full available width.
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        mediaColumn(d)
                        detailsColumn(d)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Media column (carousel + floorplans)

    @ViewBuilder
    private func mediaColumn(_ d: PropertyDetail) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ImageCarousel(urls: photoURLs(d))

            let floorplans = floorplanURLs(d)
            if !floorplans.isEmpty {
                Text(floorplans.count > 1 ? "Floorplans" : "Floorplan")
                    .font(.title3).fontWeight(.semibold)
                ForEach(Array(floorplans.enumerated()), id: \.offset) { i, url in
                    Button {
                        floorplanStartIndex = i
                        showFloorplanViewer = true
                    } label: {
                        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) }
                            placeholder: { ProgressView().frame(height: 200) }
                            .frame(maxHeight: 360)
                            .overlay(alignment: .bottomTrailing) {
                                Label("Zoom", systemImage: "plus.magnifyingglass")
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showFloorplanViewer) {
            ZoomableImageViewer(urls: floorplanURLs(d), startIndex: floorplanStartIndex, title: "Floorplan")
        }
    }

    // MARK: - Details column

    @ViewBuilder
    private func detailsColumn(_ d: PropertyDetail) -> some View {
        VStack(alignment: .leading, spacing: 24) {

            // Price + status + reduction + address + facts (always expanded)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.prices?.primaryPrice ?? "Price on application")
                        .font(.largeTitle.bold())
                    if let q = d.prices?.displayPriceQualifier, !q.isEmpty {
                        Text(q).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(state: d.listingState)
                        .font(.body)
                }
                if let badge = reductionBadge {
                    Text(badge).font(.body).foregroundStyle(.orange)
                }
                Text(Format.oneLine(d.address?.displayAddress))
                    .font(.title3).foregroundStyle(.secondary)
                factsRow(d)
            }

            // Verdict checklist (stays here, below the facts)
            verdictChecklist(d)

            // Full-address resolver (EPC match + Street View confirm)
            section("Full address") { addressResolver(d) }

            if !priceHistory.isEmpty || isLoadingPriceHistory {
                section("Price History") {
                    historicalPrices()
                }
            }

            // Map + stations (always expanded)
            if let lat = d.location?.lat, let lng = d.location?.lng {
                section("Location") {
                    stationMap(lat: lat, lng: lng, title: Format.oneLine(d.address?.displayAddress))
                }
                if !stationService.stations.isEmpty || stationService.isLoading {
                    section("Nearest stations") { stationList() }
                }
            }

            // Listing age
            listingAgeLine(d)

            Divider()

            // Collapsible sections
            if renderedDescription != nil || d.text?.description?.isEmpty == false {
                DisclosureGroup(
                    isExpanded: $descriptionExpanded) {
                        descriptionBody(d)
                            .padding(.top, 6)
                    } label: {
                        Text("Description")
                            .font(.title2).fontWeight(.semibold)
                            .clipShape(Rectangle())
                            .onTapGesture {
                                descriptionExpanded.toggle()
                            }
                    }
            }

            if let features = d.keyFeatures, !features.isEmpty {
                DisclosureGroup(
                    isExpanded: $featuresExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(features, id: \.self) { f in
                                Label(f, systemImage: "checkmark.circle").font(.body)
                            }
                        }
                        .font(.title3)
                        .padding(.top, 6)
                        .clipShape(Rectangle())
                        .onTapGesture {
                            featuresExpanded.toggle()
                        }
                    } label: {
                        Text("Key features")
                            .font(.title2).fontWeight(.semibold)
                            .clipShape(Rectangle())
                            .onTapGesture {
                                featuresExpanded.toggle()
                            }
                    }
            }

            let leaseTerms = leaseTerms(d)
            if !leaseTerms.isEmpty {
                DisclosureGroup("Lease & charges", isExpanded: $leaseExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(leaseTerms, id: \.self) { term in
                            Label(term, systemImage: "doc.plaintext").font(.body)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.headline)
            }

            if isPinned, let pin, pricePoints(pin).count >= 2 {
                DisclosureGroup("Price history (tracked)", isExpanded: $historyExpanded) {
                    priceHistoryChart(pin).padding(.top, 6)
                }
                .font(.headline)
            }

            if let url = rightmoveURL(forID: propertyID) {
                Link(destination: url) {
                    Label("View on Rightmove", systemImage: "safari")
                        .font(.headline)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Facts row (wraps)

    @ViewBuilder
    private func factsRow(_ d: PropertyDetail) -> some View {
        FlowLayout(hSpacing: 14, vSpacing: 8) {
            if let beds = d.bedrooms?.int   { Label("\(beds) bed",   systemImage: "bed.double") }
            if let baths = d.bathrooms?.int  { Label("\(baths) bath", systemImage: "shower") }
            if let type = d.propertySubType  { Label(type,            systemImage: "house") }
            if let tenure = d.tenure?.tenureType { Label(prettyTenure(tenure), systemImage: "doc.text") }
            if isLoadingFloorArea {
                Label("Calculating area…", systemImage: "ruler").redacted(reason: .placeholder)
            } else if let area = floorArea {
                Label(area.formatted, systemImage: "ruler")
                if let price = pin?.currentPriceAmount ?? d.prices?.parsedAmount, area.sqm > 0 {
                    let ppm2 = Int((Double(price) / area.sqm).rounded())
                    Label("£\(Format.thousands(ppm2))/m²", systemImage: "sterlingsign.square")
                }
            }
        }
        .font(.title2)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func prettyTenure(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Verdict checklist

    @ViewBuilder
    private func verdictChecklist(_ d: PropertyDetail) -> some View {
        let hasFloorplan  = !(d.floorplans ?? []).isEmpty
        let hasArea       = floorArea != nil && floorArea?.isApproximate == false
        let stationNearby = stationService.stations.first?.isWithin500m == true

        HStack(spacing: 16) {
            VerdictDot(label: "Floorplan",     met: hasFloorplan)
            VerdictDot(label: "Area known",    met: hasArea)
            VerdictDot(label: "Station ≤500m", met: stationNearby,
                       loading: stationService.isLoading && stationService.stations.isEmpty)
        }
        .font(.body)
    }

    // MARK: - Map + station overlays

    @ViewBuilder
    private func stationMap(lat: Double, lng: Double, title: String) -> some View {
        let propertyCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        Map(initialPosition: .region(MKCoordinateRegion(
            center: propertyCoord,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        ))) {
            Marker(title, coordinate: propertyCoord).tint(.red)

            ForEach(stationService.stations) { station in
                MapPolyline(coordinates: [propertyCoord, station.coordinate])
                    .stroke(.blue.opacity(0.75), lineWidth: 3)
            }
            ForEach(stationService.stations) { station in
                Marker(stationMarkerLabel(station), systemImage: "tram.fill", coordinate: station.coordinate)
                    .tint(.blue)
            }
        }
        .frame(height: 400)
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

    private func stationMarkerLabel(_ station: NearbyStation) -> String {
        if let info = station.formattedDistanceAndDuration { return "\(station.name)\n\(info)" }
        return station.name
    }

    @ViewBuilder
    private func stationList() -> some View {
        VStack(spacing: 6) {
            ForEach(stationService.stations) { station in
                HStack {
                    Image(systemName: "tram.fill").foregroundStyle(.blue)
                    Text(station.name).font(.body)
                    Spacer()
                    if let info = station.formattedDistanceAndDuration {
                        Text(info).font(.body.monospacedDigit()).foregroundStyle(.secondary)
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
            let verb = d.listingHistory?.verb?.lowercased() ?? ""
            let showUpdate = !verb.isEmpty && verb != "added"
            let updateText = showUpdate ? (d.listingHistory?.listingUpdateReason.map { " · \($0)" } ?? "") : ""
            Text(ageText + updateText).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Description body

    @ViewBuilder
    private func descriptionBody(_ d: PropertyDetail) -> some View {
        if let attr = renderedDescription {
            Text(String(attr.characters[...]).trimmingCharacters(in: .whitespacesAndNewlines)).font(.title3).textSelection(.enabled)
        } else if let raw = d.text?.description, !raw.isEmpty {
            Text(raw).font(.title3).textSelection(.enabled)
        }
    }

    // MARK: - Lease terms

    private func leaseTerms(_ d: PropertyDetail) -> [String] {
        (d.keyFeatures ?? []).filter { feature in
            let lower = feature.lowercased()
            return lower.contains("lease") || lower.contains("ground rent")
                || lower.contains("service charge") || lower.contains("maintenance")
        }
    }

    // MARK: - Price history chart

    @ViewBuilder
    private func priceHistoryChart(_ pin: PinnedProperty) -> some View {
        let points = pricePoints(pin)
        Chart(points) { p in
            LineMark(x: .value("Date", p.date), y: .value("Price", p.amount))
                .interpolationMethod(.stepEnd)
            PointMark(x: .value("Date", p.date), y: .value("Price", p.amount))
        }
        .frame(height: 200)
    }

    // MARK: - Historical prices (PaTMa)

    /// Chart of recorded prices over time, plus a row-per-change table.
    /// `priceHistory` arrives newest-first; the chart wants oldest-first.
    @ViewBuilder
    private func historicalPrices() -> some View {
        if isLoadingPriceHistory && priceHistory.isEmpty {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Fetching price history…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(priceHistory) { entry in
                    HStack {
                        Text(entry.date, format: .dateTime.day().month().year())
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        if entry.isFirstSeen {
                            Text("First seen").foregroundStyle(.secondary)
                        } else if let from = entry.fromAmount {
                            Text("£\(Format.thousands(from))")
                        } else if let label = entry.fromLabel {
                            Text(label).foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        if let to = entry.toAmount {
                            Text("£\(Format.thousands(to))").fontWeight(.medium)
                        } else if let label = entry.toLabel {
                            Text(label).foregroundStyle(.secondary)
                        }
                        if let delta = entry.delta, delta != 0 {
                            Text("\(delta < 0 ? "−" : "+")£\(Format.thousands(abs(delta)))")
                                .foregroundStyle(delta < 0 ? .red : .orange)
                        }
                        Spacer()
                    }
                    .font(.body.monospacedDigit())
                }

                Text("Source: PaTMa")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    /// Ask PaTMa for the property's historical prices, reusing the page HTML we
    /// already fetched. Failures are silent — the section just stays hidden.
    private func loadPriceHistory(pageURL: URL, html: String) async {
        isLoadingPriceHistory = true
        defer { isLoadingPriceHistory = false }
        let client = PATMAClient(
            sessionID: patmaSessionID.isEmpty ? nil : patmaSessionID
        )
        if let entries = try? await client.priceHistory(pageURL: pageURL, html: html) {
            priceHistory = entries
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
        return "Reduced \(reductions.count)×\(totalDrop)"
    }

    // MARK: - Address resolver

    private var cachedResolution: ResolvedAddress? {
        resolvedAddresses.first { $0.propertyID == propertyID }
    }

    @ViewBuilder
    private func addressResolver(_ d: PropertyDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cached = cachedResolution, !cached.candidates.isEmpty {
                ForEach(cached.candidates) { candidate in
                    candidateRow(candidate, cached: cached, detail: d)
                }
                Text(resolverFootnote(cached))
                    .font(.footnote).foregroundStyle(.tertiary)
                civicCrossCheckView
            } else if isResolving {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Matching sold prices & records…").foregroundStyle(.secondary)
                }
                .font(.callout)
            } else if case .noMatch(let fallback)? = resolveOutcome {
                Text("No EPC certificate matched on this street.")
                    .font(.callout).foregroundStyle(.secondary)
                if let fallback {
                    Link(destination: fallback) {
                        Label("Open Street View at the pin", systemImage: "mappin.and.ellipse")
                    }
                    .font(.callout)
                }
            } else if case .insufficientInput? = resolveOutcome {
                Text("Not enough to resolve — this listing is missing a postcode or street.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if case .failed(let message)? = resolveOutcome {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Text("Match this listing to a real address using sold-price history and EPC records.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button {
                Task { await resolveAddress(d) }
            } label: {
                Label(cachedResolution == nil ? "Resolve address" : "Re-resolve",
                      systemImage: "location.magnifyingglass")
            }
            .disabled(isResolving)
        }
    }

    /// Land Registry sold-price cross-check, shown after the user picks a
    /// candidate. Corroborates the exact civic number from the listing's sale
    /// history, or offers the close matches when it isn't conclusive.
    @ViewBuilder
    private var civicCrossCheckView: some View {
        if isCrossChecking {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Cross-checking sold prices with Land Registry…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let result = civicMatch {
            if let best = result.best {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Land Registry match: \(civicLine(best))")
                            .font(.callout.weight(.semibold))
                        if let price = best.lastSoldPrice, let year = best.lastSoldYear {
                            Text("last sold £\(price.formatted()) in \(String(year)) · \(best.matchedTransactions) matching \(best.matchedTransactions == 1 ? "sale" : "sales")")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            } else if !result.ranked.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Possible numbers from sold-price history:")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(result.ranked.prefix(3).enumerated()), id: \.offset) { _, id in
                        Text("· \(civicLine(id))")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("No Land Registry sold-price match for this postcode.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    private func civicLine(_ id: PricePaidMatcher.Identification) -> String {
        let parts: [String] = [id.civicLabel, id.street ?? ""]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func resolverFootnote(_ cached: ResolvedAddress) -> String {
        let byLandRegistry = cached.method == "landregistry"
        if cached.confirmation == .confirmed {
            return byLandRegistry
                ? "Confirmed by you · matched on Land Registry sold prices"
                : "Confirmed by you · ranked by EPC match"
        }
        return byLandRegistry
            ? "Matched on Land Registry sold prices — open Street View to confirm, then pick the match."
            : "Best guess from EPC — open Street View to confirm, then pick the match."
    }

    @ViewBuilder
    private func candidateRow(_ candidate: StoredCandidate, cached: ResolvedAddress,
                              detail: PropertyDetail) -> some View {
        let isChosen = cached.confirmation == .confirmed && candidate.address == cached.resolvedAddress
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: isChosen ? "checkmark.seal.fill" : "house")
                    .foregroundStyle(isChosen ? .green : .secondary)
                Text(candidate.address).font(.body.weight(isChosen ? .semibold : .regular))
                Spacer()
                Text("\(Int((candidate.score * 100).rounded()))%")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !candidate.matchedSignals.isEmpty {
                Text(candidate.matchedSignals.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                if let url = candidate.streetViewURL {
                    Link(destination: url) {
                        Label("Street View", systemImage: "binoculars")
                    }
                    .font(.callout)
                }
                if let url = candidate.rightmoveHistoryURL {
                    Link(destination: url) {
                        Label("Previous listings", systemImage: "clock.arrow.circlepath")
                    }
                    .font(.callout)
                }
                if !isChosen {
                    Button {
                        confirmAddress(candidate, detail: detail)
                    } label: {
                        Label("This one", systemImage: "checkmark.circle")
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(10)
        .background(isChosen ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func resolveAddress(_ d: PropertyDetail) async {
        isResolving = true
        defer { isResolving = false }
        civicMatch = nil   // stale once the candidate list changes
        let store = ResolvedAddressStore(context: context)
        resolveOutcome = await AddressResolver.resolve(detail: d, floorArea: floorArea, store: store)
    }

    private func confirmAddress(_ candidate: StoredCandidate, detail: PropertyDetail) {
        ResolvedAddressStore(context: context).confirm(propertyID: propertyID, choosing: candidate)
        // Candidates resolved via Land Registry already embed the sold-price
        // match, so only run the cross-check when resolution fell back to EPC.
        if cachedResolution?.method != "landregistry" {
            Task { await crossCheckCivicNumber(detail) }
        }
    }

    private func crossCheckCivicNumber(_ d: PropertyDetail) async {
        isCrossChecking = true
        defer { isCrossChecking = false }
        civicMatch = await AddressResolver.crossCheckCivicNumber(detail: d)
    }

    // MARK: - Section helper

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            content()
        }
    }

    // MARK: - Media URL helpers

    private func photoURLs(_ d: PropertyDetail) -> [URL] {
        (d.images ?? []).compactMap { $0.galleryURLString.flatMap(URL.init(string:)) }
    }

    private func floorplanURLs(_ d: PropertyDetail) -> [URL] {
        (d.floorplans ?? []).compactMap { $0.url.flatMap(URL.init(string:)) }
    }

    // MARK: - Price points

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
        priceHistory = []

        do {
            let page = try await model.client.fetchPropertyDetailPage(id: propertyID)
            let d = page.detail
            detail = d
            isLoading = false

            // Fetch external historical prices in the background; don't block the
            // rest of the detail render on it.
            Task { await loadPriceHistory(pageURL: page.url, html: page.html) }

            if isPinned, let snap = TrackedSnapshot(detail: d) {
                TrackingStore(context: context).apply(snap)
            }

            if let html = d.text?.description, !html.isEmpty {
                renderedDescription = html.htmlToAttributedString()
            }

            isLoadingFloorArea = true
            let floorURL = d.floorplans?.first?.url.flatMap(URL.init(string:))
            let price    = d.prices?.parsedAmount
            let ppsf     = d.prices?.pricePerSqFt
            // Prefer the floor area Rightmove already reports in the listing.
            // Only read the floorplan image when the listing carries no usable
            // size — the OCR figure is sometimes wrong, so it's a last resort.
            let responseArea = d.floorAreaSqM.map { FloorArea(sqm: $0, isApproximate: false) }

            func resolveArea() async -> FloorArea? {
                if let responseArea { return responseArea }
                return await FloorplanAnalyser.extract(
                    floorplanURL: floorURL, totalPriceGBP: price, pricePerSqFtString: ppsf)
            }

            if let lat = d.location?.lat, let lng = d.location?.lng {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                async let areaResult = resolveArea()
                async let stationTask: Void = stationService.load(near: coord)
                let (area, _) = await (areaResult, stationTask)
                floorArea = area
            } else {
                floorArea = await resolveArea()
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
