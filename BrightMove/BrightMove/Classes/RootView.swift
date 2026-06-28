import SwiftUI
import SwiftData

enum AppSection: String, CaseIterable, Identifiable {
    case search = "Search"
    case watchlist = "Watchlist"
    case changes = "Changes"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .watchlist: return "pin.fill"
        case .changes: return "clock.arrow.circlepath"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var model = AppModel()
    @State private var selection: AppSection? = .search
    @State private var path = NavigationPath()

    // "Open listing from URL" popover state.
    @State private var showOpenURL = false
    @State private var pastedURL = ""

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("PropertyBrowser")
            .frame(minWidth: 180)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    switch selection ?? .search {
                    case .search: SearchView(onSelectProperty: { path.append($0) })
                    case .watchlist: WatchlistView()
                    case .changes: ChangesFeedView()
                    }
                }
                .navigationDestination(for: Int.self) { id in
                    PropertyDetailView(propertyID: id)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showOpenURL = true
                        } label: {
                            Label("Open listing from URL", systemImage: "link")
                        }
                        .help("Open a Rightmove listing from a pasted URL")
                        .popover(isPresented: $showOpenURL, arrowEdge: .bottom) {
                            openURLPopover
                        }
                    }
                }
            }
        }
        .environment(model)
        .task { model.attach(context: context) }
    }

    // MARK: - Open from URL

    /// Property ID parsed from the current field text, or nil if it isn't a
    /// valid Rightmove listing link.
    private var pastedPropertyID: Int? {
        rightmovePropertyID(from: pastedURL)
    }

    @ViewBuilder
    private var openURLPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open listing from URL")
                .font(.headline)

            TextField("Paste a Rightmove listing link…", text: $pastedURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(openPastedURL)

            // Inline validation — only complain once something's been typed.
            if !pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               pastedPropertyID == nil {
                Label("Not a Rightmove property link", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Open", action: openPastedURL)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pastedPropertyID == nil)
            }
        }
        .padding()
    }

    private func openPastedURL() {
        guard let id = pastedPropertyID else { return }
        path.append(id)
        pastedURL = ""
        showOpenURL = false
    }
}
