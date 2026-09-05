import SwiftUI

struct EntityDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasRouter.self) private var router
    var entityType: String
    var gameID: String
    var canDeleteReference: Bool = false

    @State private var feature = EntityDetailModel()

    var body: some View {
        LoadableStateView(
            state: feature.state,
            loadingTitle: "Loading item…",
            notFoundTitle: "Item not in this snapshot",
            notFoundSystemImage: "cube",
            failedTitle: "Could not load item",
            onRefresh: { Task { await load() } },
            onDeleteReference: canDeleteReference ? deleteReference : nil
        ) { content in
            List {
                Section {
                    HStack(spacing: 12) {
                        PlaceholderIcon(
                            entityType: content.entity.entityType,
                            colorR: content.entity.colorR,
                            colorG: content.entity.colorG,
                            colorB: content.entity.colorB
                        )
                        VStack(alignment: .leading) {
                            Text(content.entity.title).font(.title2.bold())
                            Text(content.entity.entityType.capitalized)
                                .foregroundStyle(.secondary)
                            SourceBadge(presentation: content.provenance, expanded: true)
                        }
                    }
                    if let subtitle = content.entity.subtitle {
                        LabeledContent("Subtitle", value: subtitle)
                    }
                    if let category = content.entity.category {
                        LabeledContent("Category", value: category)
                    }
                    if let subcategory = content.entity.subcategory {
                        LabeledContent("Subcategory", value: subcategory)
                    }
                    if let rarity = content.entity.rarity {
                        LabeledContent("Rarity", value: rarity)
                    }
                    if let legality = content.entity.legality {
                        LabeledContent("Legality", value: legality)
                    }
                    if let value = content.entity.baseValue {
                        LabeledContent("Base value", value: value)
                    }
                }
                if let description = content.entity.description, !description.isEmpty {
                    Section("Description") { Text(description) }
                }
                if !content.produced.isEmpty {
                    Section("How to make") {
                        ForEach(content.produced) { recipe in
                            AtlasOpenLink(
                                destination: .recipe(id: recipe.recipeID),
                                section: router.selectedSection
                            ) {
                                RecipeCardView(recipe: recipe, provenance: content.provenance)
                            }
                        }
                    }
                }
                if !content.usedIn.isEmpty {
                    Section("Used in") {
                        ForEach(content.usedIn) { recipe in
                            AtlasOpenLink(
                                destination: .recipe(id: recipe.recipeID),
                                section: router.selectedSection
                            ) {
                                RecipeCardView(recipe: recipe, provenance: content.provenance)
                            }
                        }
                    }
                }
            }
            .toolbar {
                if case .loaded(let content) = feature.state {
                    Button {
                        router.open(
                            .recipePlan(
                                type: content.entity.entityType,
                                id: content.entity.gameID,
                                quantity: 1
                            ),
                            in: router.selectedSection
                        )
                    } label: {
                        Image(systemName: "list.bullet.clipboard")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Open plan")
                    Button {
                        Task { await model.saved.toggle(model.bookmark(for: content.entity)) }
                    } label: {
                        Image(
                            systemName: model.saved.isSaved(model.bookmark(for: content.entity))
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(
                        model.saved.isSaved(model.bookmark(for: content.entity))
                            ? "Remove bookmark"
                            : "Bookmark"
                    )
                }
            }
        }
        .navigationTitle(loadedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: routeKey) {
            await load()
        }
    }

    private var loadedTitle: String {
        if case .loaded(let content) = feature.state {
            return content.entity.title
        }
        return "Item"
    }

    private var routeKey: String {
        "\(entityType):\(gameID):\(model.generationID)"
    }

    @MainActor
    private func load() async {
        guard let catalog = model.catalog else {
            feature.state = .failed(CatalogError.unavailable.localizedDescription)
            return
        }
        await feature.load(
            type: entityType,
            id: gameID,
            catalog: catalog,
            packIdentity: model.packIdentity
        )
        if case .loaded(let content) = feature.state {
            await model.saved.remember(model.bookmark(for: content.entity))
        }
    }

    private func deleteReference() {
        Task {
            let key = BookmarkTarget.entity(type: entityType, gameID: gameID).stableID
            if let index = model.saved.items.firstIndex(where: { $0.id == key }) {
                await model.saved.removeItems(at: IndexSet(integer: index))
            }
            router.pop(in: router.selectedSection)
        }
    }
}
