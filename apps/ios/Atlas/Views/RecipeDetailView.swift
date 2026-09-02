import SwiftUI

struct RecipeDetailView: View {
    @Environment(AppModel.self) private var model
    var recipeID: String
    @State private var recipe: Recipe?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading recipe…")
            } else if let recipe {
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
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could not load recipe",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ContentUnavailableView("Recipe not in this snapshot", systemImage: "list.bullet")
            }
        }
        .navigationTitle(recipe?.title ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recipeID) {
            load()
        }
    }

    @MainActor
    private func load() {
        isLoading = true
        recipe = nil
        errorMessage = nil
        defer { isLoading = false }
        guard let store = model.store else {
            errorMessage = "The local Atlas pack is unavailable."
            return
        }
        do {
            guard let loadedRecipe = try store.recipe(id: recipeID) else { return }
            recipe = loadedRecipe
            model.saved.remember(savedItem(loadedRecipe))
        } catch {
            errorMessage = error.localizedDescription
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
