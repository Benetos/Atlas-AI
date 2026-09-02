import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [AtlasCard] = []
    @State private var browsing: BrowseSection = .products
    @State private var searchScope: SearchScope = .all
    @State private var browseResults: [AtlasCard] = []
    @State private var browseOffset = 0
    @State private var browseHasMore = true
    @State private var isSearching = false
    @State private var isLoadingBrowse = false
    @State private var searchError: String?
    @State private var browseError: String?

    private let pageSize = 60

    enum BrowseSection: String, CaseIterable, Identifiable {
        case products
        case substances
        case technology
        case crafting
        case refining
        case cooking

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum SearchScope: String, CaseIterable, Identifiable {
        case all
        case items
        case recipes
        case features

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    browseSection
                } else {
                    searchSection
                }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Items, recipes, expeditions, and more")
            .navigationDestination(for: AtlasRoute.self) { route in
                switch route {
                case .entity(let type, let id):
                    EntityDetailView(entityType: type, gameID: id)
                case .recipe(let id):
                    RecipeDetailView(recipeID: id)
                case .content(let dataset, let id, let sourceOrdinal):
                    ContentDetailView(dataset: dataset, externalID: id, sourceOrdinal: sourceOrdinal)
                }
            }
            .task(id: browsing) {
                await loadBrowse(reset: true)
            }
            .task(id: searchTaskID) {
                await searchAfterDebounce()
            }
        }
    }

    @ViewBuilder
    private var browseSection: some View {
        Section("Browse") {
            Picker("Category", selection: $browsing) {
                ForEach(BrowseSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.menu)

            if let browseError {
                Label(browseError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            ForEach(browseResults) { card in
                resultRow(card)
            }

            if isLoadingBrowse {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if browseHasMore && browseError == nil {
                Button("Load more") {
                    Task { await loadBrowse(reset: false) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            Picker("Search", selection: $searchScope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if isSearching {
                HStack {
                    Spacer()
                    ProgressView("Searching Atlas…")
                    Spacer()
                }
            } else if let searchError {
                ContentUnavailableView(
                    "Search unavailable",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text(searchError)
                )
            } else if results.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                ForEach(results) { card in
                    resultRow(card)
                }
            }
        } header: {
            Text("Results")
        } footer: {
            Text("Search runs entirely against the installed Atlas snapshot.")
        }
    }

    @ViewBuilder
    private func resultRow(_ card: AtlasCard) -> some View {
        switch card {
        case .entity(let entity):
            NavigationLink(value: AtlasRoute.entity(type: entity.entityType, id: entity.gameID)) {
                EntityCardView(entity: entity)
            }
        case .recipe(let recipe):
            NavigationLink(value: AtlasRoute.recipe(id: recipe.recipeID)) {
                RecipeCardView(recipe: recipe)
            }
        case .content(let record):
            NavigationLink(
                value: AtlasRoute.content(
                    dataset: record.dataset,
                    id: record.externalID,
                    sourceOrdinal: record.sourceOrdinal
                )
            ) {
                ContentCardView(record: record)
            }
        case .web(let hit):
            Link(destination: hit.url) { WebCardView(hit: hit) }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTaskID: String {
        "\(searchScope.rawValue):\(trimmedQuery)"
    }

    @MainActor
    private func searchAfterDebounce() async {
        guard !trimmedQuery.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            try runSearch()
        } catch is CancellationError {
            return
        } catch {
            results = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    @MainActor
    private func runSearch() throws {
        guard let store = model.store else { return }
        var cards: [AtlasCard] = []
        if searchScope == .all || searchScope == .items {
            cards.append(contentsOf: try store.searchEntities(query: trimmedQuery, type: nil, limit: 30).map(AtlasCard.entity))
        }
        if searchScope == .all || searchScope == .recipes {
            cards.append(contentsOf: try store.searchRecipes(query: trimmedQuery, kind: nil, limit: 30).map(AtlasCard.recipe))
        }
        if searchScope == .all || searchScope == .features {
            cards.append(contentsOf: try store.searchContent(query: trimmedQuery, dataset: nil, limit: 20).map(AtlasCard.content))
        }
        var seen: Set<String> = []
        results = cards.filter { seen.insert($0.id).inserted }
        searchError = nil
    }

    @MainActor
    private func loadBrowse(reset: Bool) async {
        guard !isLoadingBrowse, let store = model.store else { return }
        isLoadingBrowse = true
        defer { isLoadingBrowse = false }

        if reset {
            browseResults = []
            browseOffset = 0
            browseHasMore = true
        }

        do {
            let page: [AtlasCard]
            switch browsing {
            case .products, .substances, .technology:
                let type = entityType(for: browsing)
                page = try store.entities(type: type, limit: pageSize, offset: browseOffset).map(AtlasCard.entity)
            case .crafting, .refining, .cooking:
                page = try store.recipes(kind: browsing.rawValue, limit: pageSize, offset: browseOffset).map(AtlasCard.recipe)
            }
            browseResults.append(contentsOf: page)
            browseOffset += page.count
            browseHasMore = page.count == pageSize
            browseError = nil
        } catch {
            browseError = error.localizedDescription
        }
    }

    private func entityType(for section: BrowseSection) -> String {
        switch section {
        case .products: "product"
        case .substances: "substance"
        case .technology: "technology"
        default: "product"
        }
    }
}
