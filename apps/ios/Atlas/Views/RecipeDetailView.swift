import SwiftUI

struct RecipeDetailView: View {
    @Environment(AppModel.self) private var model
    var recipeID: String
    @State private var recipe: Recipe?

    var body: some View {
        Group {
            if let recipe {
                List {
                    Section {
                        LabeledContent("Kind", value: recipe.recipeKind.capitalized)
                        if let amount = recipe.outputAmount {
                            LabeledContent("Output amount", value: amount)
                        }
                        if let time = recipe.timeSeconds {
                            LabeledContent("Time (s)", value: time)
                        }
                        if let type = recipe.recipeType {
                            LabeledContent("Type", value: type)
                        }
                    }
                    Section("Output") {
                        NavigationLink(
                            value: AtlasRoute.entity(type: recipe.outputEntityType, id: recipe.outputGameID)
                        ) {
                            Text(recipe.outputTitle ?? recipe.outputGameID)
                        }
                    }
                    Section("Ingredients") {
                        ForEach(recipe.ingredients) { ingredient in
                            NavigationLink(
                                value: AtlasRoute.entity(type: ingredient.entityType, id: ingredient.gameID)
                            ) {
                                HStack {
                                    Text(ingredient.title ?? ingredient.gameID)
                                    Spacer()
                                    if let amount = ingredient.amount {
                                        Text(amount).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .toolbar {
                    Button {
                        model.saved.toggle(savedItem(recipe))
                    } label: {
                        Image(systemName: model.saved.isSaved(savedItem(recipe)) ? "bookmark.fill" : "bookmark")
                    }
                }
            } else {
                ContentUnavailableView("Recipe not in this snapshot", systemImage: "list.bullet")
            }
        }
        .navigationTitle(recipe?.title ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recipe = try? model.store?.recipe(id: recipeID)
            if let recipe {
                model.saved.remember(savedItem(recipe))
            }
        }
    }

    private func savedItem(_ recipe: Recipe) -> SavedItem {
        SavedItem(
            kind: .recipe,
            entityType: recipe.outputEntityType,
            gameID: recipe.outputGameID,
            recipeID: recipe.recipeID,
            title: recipe.title,
            savedAt: Date()
        )
    }
}
