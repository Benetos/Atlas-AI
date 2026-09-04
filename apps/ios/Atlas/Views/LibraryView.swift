import SwiftUI

@Observable
@MainActor
final class LibrarySessionModel {
    var query = ""
    var results: [AtlasCard] = []
    var browsing: LibraryView.BrowseSection = .products
    var searchScope: LibraryView.SearchScope = .all
    var browseResults: [AtlasCard] = []
    var browseOffset = 0
    var browseHasMore = true
    var isSearching = false
    var isLoadingBrowse = false
    var searchError: String?
    var browseError: String?
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibrarySessionModel.self) private var session

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
        @Bindable var session = session
        return List {
            if trimmedQuery.isEmpty {
                browseSection
            } else {
                searchSection
            }
        }
        .navigationTitle("Library")
        .searchable(text: $session.query, prompt: "Items, recipes, expeditions, and more")
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
        @Bindable var session = session
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

            Picker("Category", selection: $session.browsing) {
                ForEach(BrowseSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.menu)

            if let browseError = session.browseError {
                Label(browseError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            ForEach(session.browseResults) { card in
                resultRow(card)
            }

            if session.isLoadingBrowse {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if session.browseResults.isEmpty && session.browseError == nil {
                ContentUnavailableView(
                    "No \(session.browsing.title)",
                    systemImage: "tray",
                    description: Text(
                        isSampleDatabase
                            ? "This category is not represented in the bundled sample database."
                            : "This database has no records in this category."
                    )
                )
            } else if session.browseHasMore && session.browseError == nil {
                Button("Load more") {
                    Task { await loadBrowse(reset: false) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        @Bindable var session = session
        Section {
            Picker("Search", selection: $session.searchScope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if session.isSearching {
                HStack {
                    Spacer()
                    ProgressView("Searching Atlas…")
                    Spacer()
                }
            } else if let searchError = session.searchError {
                ContentUnavailableView(
                    "Search unavailable",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text(searchError)
                )
            } else if session.results.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                ForEach(session.results) { card in
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
                section: .library,
                replacesPath: true
            ) {
                EntityCardView(entity: entity, provenance: packedProvenance)
            }
        case .recipe(let recipe):
            AtlasOpenLink(destination: .recipe(id: recipe.recipeID), section: .library, replacesPath: true) {
                RecipeCardView(recipe: recipe, provenance: packedProvenance)
            }
        case .content(let record):
            AtlasOpenLink(
                destination: .content(
                    dataset: record.dataset,
                    id: record.externalID,
                    sourceOrdinal: record.sourceOrdinal
                ),
                section: .library,
                replacesPath: true
            ) {
                ContentCardView(record: record, provenance: packedProvenance)
            }
        case .web(let hit):
            Link(destination: hit.url) { WebCardView(hit: hit) }
        }
    }

    private var trimmedQuery: String {
        session.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTaskID: String {
        "\(session.searchScope.rawValue):\(trimmedQuery):\(model.generationID):\(model.pack?.generatedAt ?? "no-pack")"
    }

    @MainActor
    private func searchAfterDebounce() async {
        guard !trimmedQuery.isEmpty else {
            session.results = []
            session.searchError = nil
            session.isSearching = false
            return
        }
        session.isSearching = true
        session.searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            try await runSearch()
        } catch is CancellationError {
            return
        } catch {
            session.results = []
            session.searchError = error.localizedDescription
        }
        session.isSearching = false
    }

    @MainActor
    private func runSearch() async throws {
        guard let catalog = model.catalog else {
            throw CatalogError.unavailable
        }
        var cards: [AtlasCard] = []
        if session.searchScope == .all || session.searchScope == .items {
            cards.append(contentsOf: try await catalog.searchEntities(query: trimmedQuery, type: nil, limit: 30).map(AtlasCard.entity))
        }
        if session.searchScope == .all || session.searchScope == .recipes {
            cards.append(contentsOf: try await catalog.searchRecipes(query: trimmedQuery, kind: nil, limit: 30).map(AtlasCard.recipe))
        }
        if session.searchScope == .all || session.searchScope == .categories {
            cards.append(contentsOf: try await catalog.searchContent(query: trimmedQuery, dataset: nil, limit: 20).map(AtlasCard.content))
        }
        var seen: Set<String> = []
        session.results = cards.filter { seen.insert($0.id).inserted }
        session.searchError = nil
    }

    @MainActor
    private func loadBrowse(reset: Bool) async {
        guard let catalog = model.catalog else { return }
        if session.isLoadingBrowse && !reset { return }
        session.isLoadingBrowse = true
        defer { session.isLoadingBrowse = false }

        if reset {
            session.browseResults = []
            session.browseOffset = 0
            session.browseHasMore = true
        }

        do {
            let page: [AtlasCard]
            if let type = session.browsing.entityType {
                page = try await catalog.entities(type: type, limit: pageSize, offset: session.browseOffset).map(AtlasCard.entity)
            } else if let kind = session.browsing.recipeKind {
                page = try await catalog.recipes(kind: kind, limit: pageSize, offset: session.browseOffset).map(AtlasCard.recipe)
            } else if let dataset = session.browsing.contentDataset {
                page = try await catalog.contentRecords(
                    dataset: dataset,
                    limit: pageSize,
                    offset: session.browseOffset
                ).map(AtlasCard.content)
            } else {
                page = []
            }
            try Task.checkCancellation()
            session.browseResults.append(contentsOf: page)
            session.browseOffset += page.count
            session.browseHasMore = page.count == pageSize
            session.browseError = nil
        } catch is CancellationError {
            return
        } catch {
            session.browseError = error.localizedDescription
        }
    }

    private var browseTaskID: String {
        "\(session.browsing.id):\(model.generationID):\(model.pack?.generatedAt ?? "no-pack")"
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
