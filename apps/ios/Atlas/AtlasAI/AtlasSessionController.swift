import Foundation

struct AtlasReply {
    var text: String
    var cards: [AtlasCard]
    var note: String?
}

enum FoundationModelAvailability {
    case available
    case unavailable

    static var current: FoundationModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModelGate.isAvailable ? .available : .unavailable
        }
        #endif
        return .unavailable
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
enum SystemLanguageModelGate {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }
}
#endif

struct AtlasSessionController {
    var store: SQLiteNMSStore
    var settings: AppSettings

    func reply(to prompt: String) async -> AtlasReply {
        let plan = AtlasQueryPlan(prompt: prompt)
        let local: AtlasReply
        do {
            local = try gatherLocal(plan: plan)
        } catch {
            return AtlasReply(
                text: "I could not read the installed Atlas pack.",
                cards: [],
                note: "Local data failed closed; Atlas did not substitute a network source. \(error.localizedDescription)"
            )
        }
        var cards = local.cards
        var notes: [String] = []

        if FoundationModelAvailability.current == .unavailable {
            notes.append("On-device AI narration is unavailable. Showing grounded local results instead.")
        }

        if plan.requestsLive {
            if settings.liveAtlasEnabled, let query = plan.localQuery {
                do {
                    let live = try await LiveAtlasClient(settings: settings)
                        .searchEntities(query: query, type: nil)
                    let liveCards = live.map(AtlasCard.entity)
                    if !liveCards.isEmpty {
                        notes.append("Added explicitly requested live Atlas matches; packed matches take precedence.")
                        cards.append(contentsOf: liveCards.filter { liveCard in
                            !cards.contains(where: { $0.id == liveCard.id })
                        })
                    }
                } catch {
                    notes.append("Live Atlas unavailable. Showing the installed pack only.")
                }
            } else {
                notes.append("Live Atlas is off. Showing the installed pack only.")
            }
        }

        let wantsWeb = settings.webSearchEnabled && plan.requestsWeb
        if wantsWeb {
            do {
                let hits = try await WebSearchClient().search(query: plan.externalQuery)
                cards.append(contentsOf: hits.map(AtlasCard.web))
                notes.append("Web results are community/web, not Atlas recipes.")
            } catch {
                notes.append("Web search unavailable.")
            }
        }

        let spoken: String
        if FoundationModelAvailability.current == .available {
            spoken = await foundationSpokenAnswer(prompt: prompt, local: local) ?? local.text
        } else {
            spoken = local.text
        }

        return AtlasReply(
            text: spoken,
            cards: unique(cards),
            note: notes.isEmpty ? nil : notes.joined(separator: " ")
        )
    }

    private func gatherLocal(plan: AtlasQueryPlan) throws -> AtlasReply {
        let entities: [Entity]
        if let query = plan.localQuery {
            entities = try store.searchEntities(query: query, type: nil, limit: 8)
        } else {
            entities = []
        }

        var recipes: [Recipe] = []
        var content: [ContentRecord] = []

        if plan.shouldSearchRecipes, let query = plan.localQuery {
            recipes.append(
                contentsOf: try store.searchRecipes(
                    query: query,
                    kind: plan.recipeKind,
                    limit: 8
                )
            )
        }

        if let first = entities.first {
            let producing = try store.recipesProducing(type: first.entityType, id: first.gameID)
            let using = try store.recipesUsing(type: first.entityType, id: first.gameID)
            recipes.append(contentsOf: producing.filter { plan.matchesIntendedKind($0.recipeKind) })
            recipes.append(contentsOf: using.filter { plan.matchesIntendedKind($0.recipeKind) })
        }

        recipes = unique(recipes)
        if recipes.isEmpty, plan.shouldBrowseRecipes, let kind = plan.recipeKind {
            recipes = try store.recipes(kind: kind, limit: 8, offset: 0)
        }

        if let query = plan.localQuery {
            content = try store.searchContent(query: query, dataset: nil, limit: 5)
        }

        var cards: [AtlasCard] = entities.map(AtlasCard.entity)
        cards.append(contentsOf: recipes.prefix(6).map(AtlasCard.recipe))
        cards.append(contentsOf: content.map(AtlasCard.content))

        let text: String
        if entities.isEmpty && recipes.isEmpty && content.isEmpty {
            text = "I do not have a local match for that. Try a different item name, or enable web search for community sources."
        } else if plan.shouldBrowseRecipes, let kind = plan.recipeKind, entities.isEmpty {
            text = "I found \(recipes.count) \(kind) recipe(s) in the pinned Atlas snapshot."
        } else if let entity = entities.first {
            let used = recipes.filter { recipe in
                recipe.ingredients.contains {
                    $0.entityType == entity.entityType && $0.gameID == entity.gameID
                }
            }.count
            let produced = recipes.filter {
                $0.outputEntityType == entity.entityType && $0.outputGameID == entity.gameID
            }.count
            text = "\(entity.title) is a \(entity.entityType). Atlas has \(produced) recipe(s) that make it and \(used) recipe(s) that use it."
        } else {
            text = "I found \(cards.count) local result(s) in the pinned Atlas snapshot."
        }
        return AtlasReply(text: text, cards: unique(cards), note: nil)
    }

    private func foundationSpokenAnswer(prompt: String, local: AtlasReply) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return await FoundationModelsAtlas.run(prompt: prompt, local: local, store: store)
        }
        #endif
        return nil
    }

    private func unique(_ cards: [AtlasCard]) -> [AtlasCard] {
        var seen: Set<String> = []
        return cards.filter { seen.insert($0.id).inserted }
    }

    private func unique(_ recipes: [Recipe]) -> [Recipe] {
        var seen: Set<String> = []
        return recipes.filter { seen.insert($0.recipeID).inserted }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
enum FoundationModelsAtlas {
    static let instructions = """
    You are Atlas, a No Man's Sky reference assistant. You may only state facts \
    returned by tools or provided in the grounded local results. If tools miss, say so. \
    Never invent recipes, ingredients, or item stats. Never merge a web snippet into \
    an Atlas recipe. If a web result disagrees with Atlas data, keep the Atlas fact \
    and label the web result as community/web.
    """

    static func run(
        prompt: String,
        local: AtlasReply,
        store: SQLiteNMSStore
    ) async -> String? {
        do {
            let grounded = groundedContext(local)
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: LocalDatabaseToolRegistry.make(store: store),
                instructions: Instructions(instructions)
            )
            let response = try await session.respond(to: "\(prompt)\n\nGrounded local results:\n\(grounded)")
            return response.content
        } catch {
            return nil
        }
    }

    private static func groundedContext(_ local: AtlasReply) -> String {
        let names = local.cards.compactMap { card -> String? in
            switch card {
            case .entity(let entity): return "entity \(entity.title) (\(entity.entityType)/\(entity.gameID))"
            case .recipe(let recipe): return "recipe \(recipe.title) (\(recipe.recipeKind))"
            case .content(let record): return "content \(record.dataset) \(record.title)"
            case .web: return nil
            }
        }
        return names.isEmpty ? "none" : names.joined(separator: "; ")
    }
}

/// The complete model-callable database surface. Its concrete initializer only
/// accepts the installed SQLite pack, so a network repository cannot be
/// registered accidentally as an Atlas database tool.
@available(iOS 26.0, macOS 26.0, *)
enum LocalDatabaseToolRegistry {
    static let expectedNames = [
        "search_entities",
        "get_entity",
        "recipes_for",
        "recipes_using",
        "search_content",
    ]

    static func make(store: SQLiteNMSStore) -> [any Tool] {
        [
            SearchEntitiesTool(store: store),
            GetEntityTool(store: store),
            RecipesForTool(store: store),
            RecipesUsingTool(store: store),
            SearchContentTool(store: store),
        ]
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct SearchEntitiesTool: Tool {
    let store: SQLiteNMSStore
    let name = "search_entities"
    let description = "Search local Atlas products, substances, and technologies."

    @Generable
    struct Arguments {
        var query: String
        var entityType: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let rows = try store.searchEntities(query: arguments.query, type: arguments.entityType, limit: 8)
        return encode(rows.map { ["title": $0.title, "type": $0.entityType, "id": $0.gameID] })
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct GetEntityTool: Tool {
    let store: SQLiteNMSStore
    let name = "get_entity"
    let description = "Load one local Atlas entity by type and game id."

    @Generable
    struct Arguments {
        var entityType: String
        var gameId: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let entity = try store.entity(type: arguments.entityType, id: arguments.gameId) else {
            return "{\"error\":\"not found\"}"
        }
        return encode([
            "title": entity.title,
            "type": entity.entityType,
            "id": entity.gameID,
            "subtitle": entity.subtitle ?? "",
            "description": entity.description ?? "",
        ])
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct RecipesForTool: Tool {
    let store: SQLiteNMSStore
    let name = "recipes_for"
    let description = "List local recipes that output an entity."

    @Generable
    struct Arguments {
        var entityType: String
        var gameId: String
    }

    func call(arguments: Arguments) async throws -> String {
        let rows = try store.recipesProducing(type: arguments.entityType, id: arguments.gameId)
        return encode(rows.map { recipeJSON($0) })
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct RecipesUsingTool: Tool {
    let store: SQLiteNMSStore
    let name = "recipes_using"
    let description = "List local recipes that consume an entity as an ingredient."

    @Generable
    struct Arguments {
        var entityType: String
        var gameId: String
    }

    func call(arguments: Arguments) async throws -> String {
        let rows = try store.recipesUsing(type: arguments.entityType, id: arguments.gameId)
        return encode(rows.map { recipeJSON($0) })
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct SearchContentTool: Tool {
    let store: SQLiteNMSStore
    let name = "search_content"
    let description = "Search packed feature records such as expeditions or fish."

    @Generable
    struct Arguments {
        var query: String
        var dataset: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let rows = try store.searchContent(query: arguments.query, dataset: arguments.dataset, limit: 8)
        return encode(rows.map { ["dataset": $0.dataset, "id": $0.externalID, "title": $0.title] })
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func recipeJSON(_ recipe: Recipe) -> [String: Any] {
    [
        "id": recipe.recipeID,
        "kind": recipe.recipeKind,
        "title": recipe.title,
        "output": [
            "type": recipe.outputEntityType,
            "id": recipe.outputGameID,
            "title": recipe.outputTitle ?? recipe.outputGameID,
            "amount": recipe.outputAmount ?? "",
        ],
        "ingredients": recipe.ingredients.map { ingredient in
            [
                "position": ingredient.position,
                "type": ingredient.entityType,
                "id": ingredient.gameID,
                "title": ingredient.title ?? ingredient.gameID,
                "amount": ingredient.amount ?? "",
            ] as [String: Any]
        },
    ]
}

@available(iOS 26.0, macOS 26.0, *)
private func encode(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let text = String(data: data, encoding: .utf8)
    else { return "[]" }
    return text
}
#endif
