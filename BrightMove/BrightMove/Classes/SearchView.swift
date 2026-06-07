import SwiftUI
import SwiftData
import RightmoveKit
import PropertyStore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query private var pins: [PinnedProperty]

    /// Pushes a property detail onto the navigation stack owned by `RootView`.
    /// Used by the map callout, which can't use a `NavigationLink`.
    var onSelectProperty: (Int) -> Void = { _ in }

    @FocusState private var areaFieldFocused: Bool
    @State private var areaFieldHeight: CGFloat = 0

    private var pinnedIDs: Set<Int> { Set(pins.map(\.propertyID)) }

    // Bedroom picker options: label -> stored value ("" == any, "0" == studio).
    private let bedroomOptions: [(label: String, value: String)] = [
        ("Any", ""), ("Studio", "0"), ("1+", "1"), ("2+", "2"),
        ("3+", "3"), ("4+", "4"), ("5+", "5"), ("6+", "6"),
    ]

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            searchForm($model)
                .padding()

            Divider()

            if let error = model.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            resultsBar

            if model.searchViewMode == .list {
                listSection
            } else {
                mapSection
            }
        }
        .navigationTitle("Search")
    }

    // MARK: Results bar (count + view-mode toggle + map disclosures)

    private var mappedResults: [SearchProperty] {
        model.results.filter { $0.location?.lat != nil && $0.location?.lng != nil }
    }

    private var unmappedCount: Int { model.results.count - mappedResults.count }

    private var viewModeBinding: Binding<AppModel.SearchViewMode> {
        Binding(
            get: { model.searchViewMode },
            set: { newValue in
                if newValue == .map { model.enterMapMode() } else { model.exitMapMode() }
            }
        )
    }

    @ViewBuilder
    private var resultsBar: some View {
        if model.resultCount != nil || !model.results.isEmpty {
            HStack(spacing: 12) {
                if let count = model.resultCount {
                    Text("\(count) results — showing \(model.results.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.searchViewMode == .map {
                    if unmappedCount > 0 {
                        Text("\(unmappedCount) not shown on map")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.didCapMapLoad {
                        Text("showing first \(model.results.count) — narrow your search")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Picker("View:", selection: viewModeBinding) {
                    Label("Grid", image: "square.grid.2x2").tag(AppModel.SearchViewMode.list)
                    Label("Map", image: "map").tag(AppModel.SearchViewMode.map)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    // MARK: List + map sections

    @ViewBuilder
    private var listSection: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(model.results, id: \.listingKey) { property in
                    if let id = property.propertyID {
                        NavigationLink(value: id) {
                            PropertyCard(
                                data: property,
                                isPinned: pinnedIDs.contains(id),
                                onTogglePin: { togglePin(property) }
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // Auto-load the next page as the last card scrolls
                            // into view.
                            if property.listingKey == model.results.last?.listingKey {
                                Task { await model.loadNextPage() }
                            }
                        }
                    }
                }
            }
            .padding()

            paginationFooter
        }
        .overlay {
            if model.results.isEmpty && !model.isSearching {
                ContentUnavailableView(
                    "No results",
                    systemImage: "magnifyingglass",
                    description: Text("Set your search criteria above and tap Search.")
                )
            }
        }
    }

    @ViewBuilder
    private var mapSection: some View {
        PropertyMapView(
            properties: mappedResults,
            pinnedIDs: pinnedIDs,
            fitToken: model.fitToken,
            fallbackCenter: nil,
            onSelect: { id in onSelectProperty(id) },
            onTogglePin: { id in togglePinByID(id) }
        )
        .overlay {
            if mappedResults.isEmpty && !model.isSearching {
                ContentUnavailableView(
                    "No mappable results",
                    systemImage: "map",
                    description: Text("None of these results have a location to show on the map.")
                )
            }
        }
    }

    // MARK: Pagination footer

    /// Shown beneath the grid: a spinner while a page loads, a manual "Load
    /// more" fallback when there's more to fetch, or an end-of-results note.
    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if model.canLoadMore {
            Button("Load more") {
                Task { await model.loadNextPage() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if !model.results.isEmpty {
            Text("End of results")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    // MARK: Form

    @ViewBuilder
    private func searchForm(_ model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            areaField(model)

            HStack(alignment: .bottom, spacing: 12) {
                labeledControl("Radius") {
                    Picker("", selection: model.criteria.radius) {
                        ForEach(SearchRadius.allCases) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .labelsHidden()
                }

                labeledControl("Bedrooms") {
                    Picker("", selection: bedroomBinding(model)) {
                        ForEach(bedroomOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .labelsHidden()
                }

                labeledControl("Property type") {
                    propertyTypeMenu(model)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                labeledControl("Min price (£)") {
                    TextField("No min", text: model.minPriceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                labeledControl("Max price (£)") {
                    TextField("No max", text: model.maxPriceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                Spacer()

                Button {
                    Task { await model.wrappedValue.runSearch() }
                } label: {
                    if model.wrappedValue.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Search").frame(minWidth: 60)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.wrappedValue.canSearch)
            }
        }
    }

    @ViewBuilder
    private func areaField(_ model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Area").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Town, postcode, or station…", text: model.locationQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($areaFieldFocused)
                    .onChange(of: model.wrappedValue.locationQuery) {
                        model.wrappedValue.locationQueryChanged()
                    }
                    .onChange(of: areaFieldFocused) {
                        // Dismiss the dropdown when the field loses focus, but
                        // defer briefly so a click on a suggestion registers first
                        // (the click blurs the field before its action runs).
                        guard !areaFieldFocused else { return }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            if !areaFieldFocused {
                                model.wrappedValue.dismissSuggestions()
                            }
                        }
                    }
                    .onExitCommand {
                        // Escape hides the dropdown.
                        model.wrappedValue.dismissSuggestions()
                    }
                if model.wrappedValue.isLookingUp {
                    ProgressView().controlSize(.small)
                } else if model.wrappedValue.criteria.hasLocation {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }

            if let err = model.wrappedValue.lookupError {
                Text(err).font(.caption).foregroundStyle(.secondary)
            }
        }
        .background(
            // Measure the area field's own height so the dropdown can be offset
            // to sit just below it.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { areaFieldHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, h in areaFieldHeight = h }
            }
        )
        .zIndex(10)
        .overlay(alignment: .topLeading) {
            if !model.wrappedValue.locationSuggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.wrappedValue.locationSuggestions) { s in
                            Button {
                                model.wrappedValue.selectLocation(s)
                            } label: {
                                HStack {
                                    Image(systemName: "mappin.circle")
                                        .foregroundStyle(.secondary)
                                    Text(s.displayName)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 200, maxHeight: 400)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
                .shadow(radius: 8, y: 4)
                // Drop the list straight down so its top sits just below the area
                // field, floating over the controls beneath.
                .offset(y: areaFieldHeight + 4)
            }
        }
    }

    @ViewBuilder
    private func propertyTypeMenu(_ model: Bindable<AppModel>) -> some View {
        Menu {
            ForEach(PropertyTypeFilter.allCases) { type in
                Toggle(type.label, isOn: propertyTypeBinding(model, type))
            }
        } label: {
            Text(propertyTypeSummary(model.wrappedValue.criteria.propertyTypes))
                .frame(minWidth: 110, alignment: .leading)
        }
        .frame(width: 150)
    }

    private func propertyTypeSummary(_ types: [PropertyTypeFilter]) -> String {
        switch types.count {
        case 0: return "Any"
        case 1: return types[0].label
        default: return "\(types.count) selected"
        }
    }

    @ViewBuilder
    private func labeledControl<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Bindings

    private func bedroomBinding(_ model: Bindable<AppModel>) -> Binding<String> {
        Binding(
            get: { model.wrappedValue.criteria.minBedrooms ?? "" },
            set: { model.wrappedValue.criteria.minBedrooms = $0.isEmpty ? nil : $0 }
        )
    }

    private func propertyTypeBinding(_ model: Bindable<AppModel>, _ type: PropertyTypeFilter) -> Binding<Bool> {
        Binding(
            get: { model.wrappedValue.criteria.propertyTypes.contains(type) },
            set: { isOn in
                var types = model.wrappedValue.criteria.propertyTypes
                if isOn {
                    if !types.contains(type) { types.append(type) }
                } else {
                    types.removeAll { $0 == type }
                }
                model.wrappedValue.criteria.propertyTypes = types
            }
        )
    }

    private func togglePinByID(_ id: Int) {
        guard let property = model.results.first(where: { $0.propertyID == id }) else { return }
        togglePin(property)
    }

    private func togglePin(_ property: SearchProperty) {
        guard let id = property.propertyID else { return }
        let store = TrackingStore(context: context)
        if store.isPinned(id: id) {
            store.unpin(id: id)
        } else if let snapshot = TrackedSnapshot(search: property) {
            store.pin(snapshot, sourceSearchURL: model.lastSearchURLString)
        }
    }
}

