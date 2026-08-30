import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [AtlasCard] = []
    @State private var browsing: BrowseSection = .products

    enum BrowseSection: String, CaseIterable, Identifiable {
        case products
        case substances
        case technology
        case crafting
        case refining
        case cooking

        var id: String { rawValue }

        var title: String {
            rawValue.capitalized
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search the local snapshot", text: $query)
                        .textInputAutocapitalization(.never)
                        .onSubmit { runSearch() }
                    if !results.isEmpty {
                        ForEach(results) { card in
                            resultRow(card)
                        }
                    }
                }

                Section("Browse") {
                    Picker("Section", selection: $browsing) {
                        ForEach(BrowseSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    browseRows
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: AtlasRoute.self) { route in
                switch route {
                case .entity(let type, let id):
                    EntityDetailView(entityType: type, gameID: id)
                case .recipe(let id):
                    RecipeDetailView(recipeID: id)
                }
            }
        }
    }

    @ViewBuilder
    private var browseRows: some View {
        if let store = model.store {
            switch browsing {
            case .products, .substances, .technology:
                let type = entityType(for: browsing)
                ForEach((try? store.entities(type: type, limit: 80, offset: 0)) ?? []) { entity in
                    NavigationLink(value: AtlasRoute.entity(type: entity.entityType, id: entity.gameID)) {
                        EntityCardView(entity: entity)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            case .crafting, .refining, .cooking:
                let kind = browsing.rawValue
                ForEach((try? store.recipes(kind: kind, limit: 80, offset: 0)) ?? []) { recipe in
                    NavigationLink(value: AtlasRoute.recipe(id: recipe.recipeID)) {
                        RecipeCardView(recipe: recipe)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            }
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
            ContentCardView(record: record)
        case .web(let hit):
            Link(destination: hit.url) { WebCardView(hit: hit) }
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

    private func runSearch() {
        guard let store = model.store else { return }
        let entities = (try? store.searchEntities(query: query, type: nil, limit: 20)) ?? []
        let content = (try? store.searchContent(query: query, dataset: nil, limit: 10)) ?? []
        var cards = entities.map(AtlasCard.entity)
        cards.append(contentsOf: content.map(AtlasCard.content))
        results = cards
    }
}
