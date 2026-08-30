import SwiftUI

struct EntityDetailView: View {
    @Environment(AppModel.self) private var model
    var entityType: String
    var gameID: String

    @State private var entity: Entity?
    @State private var produced: [Recipe] = []
    @State private var usedIn: [Recipe] = []

    var body: some View {
        Group {
            if let entity {
                List {
                    Section {
                        HStack(spacing: 12) {
                            PlaceholderIcon(
                                entityType: entity.entityType,
                                colorR: entity.colorR,
                                colorG: entity.colorG,
                                colorB: entity.colorB
                            )
                            VStack(alignment: .leading) {
                                Text(entity.title).font(.title2.bold())
                                Text(entity.entityType.capitalized)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let subtitle = entity.subtitle { LabeledContent("Subtitle", value: subtitle) }
                        if let category = entity.category { LabeledContent("Category", value: category) }
                        if let subcategory = entity.subcategory { LabeledContent("Subcategory", value: subcategory) }
                        if let rarity = entity.rarity { LabeledContent("Rarity", value: rarity) }
                        if let legality = entity.legality { LabeledContent("Legality", value: legality) }
                        if let value = entity.baseValue { LabeledContent("Base value", value: value) }
                    }
                    if let description = entity.description, !description.isEmpty {
                        Section("Description") { Text(description) }
                    }
                    if !produced.isEmpty {
                        Section("Crafted from") {
                            ForEach(produced) { recipe in
                                NavigationLink(value: AtlasRoute.recipe(id: recipe.recipeID)) {
                                    RecipeCardView(recipe: recipe)
                                }
                            }
                        }
                    }
                    if !usedIn.isEmpty {
                        Section("Used in") {
                            ForEach(usedIn) { recipe in
                                NavigationLink(value: AtlasRoute.recipe(id: recipe.recipeID)) {
                                    RecipeCardView(recipe: recipe)
                                }
                            }
                        }
                    }
                }
                .toolbar {
                    Button {
                        model.saved.toggle(savedItem(entity))
                    } label: {
                        Image(systemName: model.saved.isSaved(savedItem(entity)) ? "bookmark.fill" : "bookmark")
                    }
                }
            } else {
                ContentUnavailableView("Item not in this snapshot", systemImage: "cube")
            }
        }
        .navigationTitle(entity?.title ?? "Item")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard let store = model.store else { return }
        entity = try? store.entity(type: entityType, id: gameID)
        produced = (try? store.recipesProducing(type: entityType, id: gameID)) ?? []
        usedIn = (try? store.recipesUsing(type: entityType, id: gameID)) ?? []
        if let entity {
            model.saved.remember(savedItem(entity))
        }
    }

    private func savedItem(_ entity: Entity) -> SavedItem {
        SavedItem(
            kind: .entity,
            entityType: entity.entityType,
            gameID: entity.gameID,
            recipeID: nil,
            title: entity.title,
            savedAt: Date()
        )
    }
}
