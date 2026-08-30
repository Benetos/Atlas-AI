import SwiftUI

struct SavedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Bookmarks") {
                    if model.saved.items.isEmpty {
                        Text("Bookmark items and recipes from their detail screens.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.saved.items) { item in
                            savedLink(item)
                        }
                    }
                }
                Section("Recents") {
                    ForEach(model.saved.recents) { item in
                        savedLink(item)
                    }
                }
            }
            .navigationTitle("Saved")
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
    private func savedLink(_ item: SavedItem) -> some View {
        switch item.kind {
        case .entity:
            NavigationLink(value: AtlasRoute.entity(type: item.entityType ?? "", id: item.gameID ?? "")) {
                Text(item.title)
            }
        case .recipe:
            NavigationLink(value: AtlasRoute.recipe(id: item.recipeID ?? "")) {
                Text(item.title)
            }
        }
    }
}
