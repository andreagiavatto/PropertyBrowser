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

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("PropertyBrowser")
            .frame(minWidth: 180)
        } detail: {
            NavigationStack {
                Group {
                    switch selection ?? .search {
                    case .search: SearchView()
                    case .watchlist: WatchlistView()
                    case .changes: ChangesFeedView()
                    }
                }
                .navigationDestination(for: Int.self) { id in
                    PropertyDetailView(propertyID: id)
                }
            }
        }
        .environment(model)
        .task { model.attach(context: context) }
    }
}
