import SwiftUI
import SwiftData
import RightmoveKit
import PropertyStore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query private var pins: [PinnedProperty]

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

            if let count = model.resultCount {
                Text("\(count) results — showing \(model.results.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

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
                        }
                    }
                }
                .padding()
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
        .navigationTitle("Search")
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
                    .onChange(of: model.wrappedValue.locationQuery) {
                        model.wrappedValue.locationQueryChanged()
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

            if !model.wrappedValue.locationSuggestions.isEmpty {
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
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxHeight: 200)
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

