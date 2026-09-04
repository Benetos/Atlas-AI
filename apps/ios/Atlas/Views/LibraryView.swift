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
        case products = "product"
        case substances = "substance"
        case technology
        case crafting
        case refining
        case cooking
        case bait
        case buildingParts = "building_parts"
        case corvetteParts = "corvette_parts"
        case expeditions
        case fish
        case fossils
        case legacyItems = "legacy_items"
        case buildingBlueprints = "purchaseable_building_blueprints"
        case shipParts = "ship_parts"
        case specialPurchases = "special_purchases"
        case specialRewards = "special_rewards"
        case stories

        var id: String { rawValue }

        var title: String {
            switch self {
            case .products: "Products"
            case .substances: "Substances"
            case .technology: "Technology"
            case .crafting: "Crafting"
            case .refining: "Refining"
            case .cooking: "Cooking"
            case .bait: "Bait"
            case .buildingParts: "Building Parts"
            case .corvetteParts: "Corvette Parts"
            case .expeditions: "Expeditions"
            case .fish: "Fish"
            case .fossils: "Fossils"
            case .legacyItems: "Legacy Items"
            case .buildingBlueprints: "Building Blueprints"
            case .shipParts: "Ship Parts"
            case .specialPurchases: "Special Purchases"
            case .specialRewards: "Special Rewards"
            case .stories: "Stories"
            }
        }

        var entityType: String? {
            switch self {
            case .products, .substances, .technology: rawValue
            default: nil
            }
        }

        var recipeKind: String? {
            switch self {
            case .crafting, .refining, .cooking: rawValue
            default: nil
            }
        }

        var contentDataset: String? {
            entityType == nil && recipeKind == nil ? rawValue : nil
        }
    }

    enum SearchScope: String, CaseIterable, Identifiable {
        case all
        case items
        case recipes
        case categories

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                browseSection
            } else {
                searchSection
            }
        }
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Items, recipes, expeditions, and more")
        .task(id: browseTaskID) {
            await loadBrowse(reset: true)
        }
        .task(id: searchTaskID) {
            await searchAfterDebounce()
        }
    }

    private var packedProvenance: SourcePresentation {
        .packed(model.packIdentity)
    }

    @ViewBuilder
    private var browseSection: some View {
        Section("Browse") {
            if isSampleDatabase {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sample database", systemImage: "shippingbox")
                        .font(.headline)
                    Text("This build contains only \(databaseCountSummary). Categories without a sample will be empty until the full Debug database is bundled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

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
            } else if browseResults.isEmpty && browseError == nil {
                ContentUnavailableView(
                    "No \(browsing.title)",
                    systemImage: "tray",
                    description: Text(
                        isSampleDatabase
                            ? "This category is not represented in the bundled sample database."
                            : "This database has no records in this category."
                    )
                )
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
            AtlasOpenLink(
                destination: .entity(type: entity.entityType, id: entity.gameID),
                section: .library
            ) {
                EntityCardView(entity: entity, provenance: packedProvenance)
            }
        case .recipe(let recipe):
            AtlasOpenLink(destination: .recipe(id: recipe.recipeID), section: .library) {
                RecipeCardView(recipe: recipe, provenance: packedProvenance)
            }
        case .content(let record):
            AtlasOpenLink(
                destination: .content(
                    dataset: record.dataset,
                    id: record.externalID,
                    sourceOrdinal: record.sourceOrdinal
                ),
                section: .library
            ) {
                ContentCardView(record: record, provenance: packedProvenance)
            }
        case .web(let hit):
            Link(destination: hit.url) { WebCardView(hit: hit) }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTaskID: String {
        "\(searchScope.rawValue):\(trimmedQuery):\(model.generationID):\(model.pack?.generatedAt ?? "no-pack")"
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
            try await runSearch()
        } catch is CancellationError {
            return
        } catch {
            results = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    @MainActor
    private func runSearch() async throws {
        guard let catalog = model.catalog else {
            throw CatalogError.unavailable
        }
        var cards: [AtlasCard] = []
        if searchScope == .all || searchScope == .items {
            cards.append(contentsOf: try await catalog.searchEntities(query: trimmedQuery, type: nil, limit: 30).map(AtlasCard.entity))
        }
        if searchScope == .all || searchScope == .recipes {
            cards.append(contentsOf: try await catalog.searchRecipes(query: trimmedQuery, kind: nil, limit: 30).map(AtlasCard.recipe))
        }
        if searchScope == .all || searchScope == .categories {
            cards.append(contentsOf: try await catalog.searchContent(query: trimmedQuery, dataset: nil, limit: 20).map(AtlasCard.content))
        }
        var seen: Set<String> = []
        results = cards.filter { seen.insert($0.id).inserted }
        searchError = nil
    }

    @MainActor
    private func loadBrowse(reset: Bool) async {
        guard !isLoadingBrowse, let catalog = model.catalog else { return }
        isLoadingBrowse = true
        defer { isLoadingBrowse = false }

        if reset {
            browseResults = []
            browseOffset = 0
            browseHasMore = true
        }

        do {
            let page: [AtlasCard]
            if let type = browsing.entityType {
                page = try await catalog.entities(type: type, limit: pageSize, offset: browseOffset).map(AtlasCard.entity)
            } else if let kind = browsing.recipeKind {
                page = try await catalog.recipes(kind: kind, limit: pageSize, offset: browseOffset).map(AtlasCard.recipe)
            } else if let dataset = browsing.contentDataset {
                page = try await catalog.contentRecords(
                    dataset: dataset,
                    limit: pageSize,
                    offset: browseOffset
                ).map(AtlasCard.content)
            } else {
                page = []
            }
            browseResults.append(contentsOf: page)
            browseOffset += page.count
            browseHasMore = page.count == pageSize
            browseError = nil
        } catch {
            browseError = error.localizedDescription
        }
    }

    private var browseTaskID: String {
        "\(browsing.id):\(model.generationID):\(model.pack?.generatedAt ?? "no-pack")"
    }

    private var packCounts: [String: Int] {
        model.pack?.counts ?? [:]
    }

    private var isSampleDatabase: Bool {
        let total = model.pack?.searchableRecordCount ?? 0
        return total > 0 && total < 1_000
    }

    private var databaseCountSummary: String {
        let entities = packCounts["entities", default: 0]
        let recipes = packCounts["recipes", default: 0]
        let content = packCounts["content_records", default: 0]
        return "\(entities) items, \(recipes) recipes, and \(content) category record\(content == 1 ? "" : "s")"
    }
}
