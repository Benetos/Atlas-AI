import SwiftUI

struct RecipeDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasRouter.self) private var router
    var recipeID: String
    var canDeleteReference: Bool = false

    @State private var feature = RecipeDetailModel()

    var body: some View {
        LoadableStateView(
            state: feature.state,
            loadingTitle: "Loading recipe…",
            notFoundTitle: "Recipe not in this snapshot",
            notFoundSystemImage: "list.bullet",
            failedTitle: "Could not load recipe",
            onRefresh: { Task { await load() } },
            onDeleteReference: canDeleteReference ? deleteReference : nil
        ) { content in
            List {
                Section {
                    LabeledContent("Kind", value: content.recipe.recipeKind.capitalized)
                    if let amount = content.recipe.outputAmount {
                        LabeledContent("Output amount", value: amount)
                    }
                    if let time = content.recipe.timeSeconds {
                        LabeledContent("Time (s)", value: time)
                    }
                    if let type = content.recipe.recipeType {
                        LabeledContent("Type", value: type)
                    }
                    SourceBadge(presentation: content.provenance, expanded: true)
                }
                Section("Output") {
                    AtlasOpenLink(
                        destination: .entity(
                            type: content.recipe.outputEntityType,
                            id: content.recipe.outputGameID
                        ),
                        section: router.selectedSection
                    ) {
                        Text(content.recipe.outputTitle ?? content.recipe.outputGameID)
                    }
                }
                Section("Ingredients") {
                    ForEach(content.recipe.ingredients) { ingredient in
                        AtlasOpenLink(
                            destination: .entity(type: ingredient.entityType, id: ingredient.gameID),
                            section: router.selectedSection
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
                    let quantity = (try? Quantity.parse(content.recipe.outputAmount ?? "1")) ?? 1
                    router.open(
                        .recipePlan(
                            type: content.recipe.outputEntityType,
                            id: content.recipe.outputGameID,
                            quantity: quantity
                        ),
                        in: router.selectedSection
                    )
                } label: {
                    Image(systemName: "list.bullet.clipboard")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Open plan for output")
                Button {
                    Task { await model.saved.toggle(model.bookmark(for: content.recipe)) }
                } label: {
                    Image(
                        systemName: model.saved.isSaved(model.bookmark(for: content.recipe))
                            ? "bookmark.fill"
                            : "bookmark"
                    )
                    .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(
                    model.saved.isSaved(model.bookmark(for: content.recipe))
                        ? "Remove bookmark"
                        : "Bookmark"
                )
            }
        }
        .navigationTitle(loadedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(recipeID):\(model.generationID)") {
            await load()
        }
    }

    private var loadedTitle: String {
        if case .loaded(let content) = feature.state {
            return content.recipe.title
        }
        return "Recipe"
    }

    @MainActor
    private func load() async {
        guard let catalog = model.catalog else {
            feature.state = .failed(CatalogError.unavailable.localizedDescription)
            return
        }
        await feature.load(id: recipeID, catalog: catalog, packIdentity: model.packIdentity)
        if case .loaded(let content) = feature.state {
            await model.saved.remember(model.bookmark(for: content.recipe))
        }
    }

    private func deleteReference() {
        Task {
            let key = BookmarkTarget.recipe(id: recipeID).stableID
            if let index = model.saved.items.firstIndex(where: { $0.id == key }) {
                await model.saved.removeItems(at: IndexSet(integer: index))
            }
            router.pop(in: router.selectedSection)
        }
    }
}
