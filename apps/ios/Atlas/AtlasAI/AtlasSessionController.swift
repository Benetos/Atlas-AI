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

    /// Returns the authoritative database-backed response. Optional model prose
    /// is deliberately separate so the caller can impose a short deadline and
    /// retain this result on timeout or failure.
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

        return AtlasReply(
            text: local.text,
            cards: unique(cards),
            note: notes.isEmpty ? nil : notes.joined(separator: " ")
        )
    }

    /// Produces optional prose from an already-complete grounded response.
    /// Callers may time out or cancel this and safely use the database answer.
    func narration(to prompt: String, grounded: AtlasReply) async -> String? {
        guard FoundationModelAvailability.current == .available,
              grounded.cards.contains(where: { card in
                  if case .web = card { return false }
                  return true
              })
        else { return nil }
        return await foundationSpokenAnswer(prompt: prompt, local: grounded)
    }

    private func gatherLocal(plan: AtlasQueryPlan) throws -> AtlasReply {
        var entities: [Entity] = []
        if plan.shouldBrowseEntities, let entityType = plan.entityType {
            entities = try store.entities(type: entityType, limit: 8, offset: 0)
        } else if !plan.shouldBrowseRecipes {
            for query in plan.localSearchQueries {
                entities.append(
                    contentsOf: try store.searchEntities(
                        query: query,
                        type: plan.entityType,
                        limit: 8
                    )
                )
                entities = unique(entities)
                if entities.count >= 8 { break }
            }
        }

        var recipes: [Recipe] = []
        var content: [ContentRecord] = []

        // A uses question must show recipes that consume the item. A generic
        // recipe-name search mostly finds recipes that produce it and can crowd
        // the requested relationships out of the bounded card list.
        if plan.shouldSearchRecipes, plan.goal != .uses {
            for query in plan.localSearchQueries {
                recipes.append(contentsOf: try store.searchRecipes(
                    query: query,
                    kind: plan.recipeKind,
                    limit: 8
                ))
                recipes = unique(recipes)
                if recipes.count >= 8 { break }
            }
        }

        if let first = entities.first {
            switch plan.goal {
            case .uses:
                let using = try store.recipesUsing(type: first.entityType, id: first.gameID, limit: 8)
                recipes.append(contentsOf: using.filter { plan.matchesIntendedKind($0.recipeKind) })
            case .recipe:
                let producing = try store.recipesProducing(type: first.entityType, id: first.gameID, limit: 8)
                recipes.append(contentsOf: producing.filter { plan.matchesIntendedKind($0.recipeKind) })
                if plan.operation != nil {
                    let using = try store.recipesUsing(type: first.entityType, id: first.gameID, limit: 8)
                    recipes.append(contentsOf: using.filter { plan.matchesIntendedKind($0.recipeKind) })
                }
            case .lookup, .browseEntities, .browseRecipes:
                break
            }
        }

        recipes = unique(recipes)
        if recipes.isEmpty, plan.shouldBrowseRecipes {
            recipes = try store.recipes(kind: plan.recipeKind, limit: 8, offset: 0)
        }

        if !plan.shouldBrowseRecipes {
            for query in plan.localSearchQueries {
                content.append(contentsOf: try store.searchContent(query: query, dataset: nil, limit: 5))
                content = unique(content)
                if content.count >= 5 { break }
            }
        }

        var cards: [AtlasCard] = entities.prefix(8).map(AtlasCard.entity)
        cards.append(contentsOf: recipes.prefix(6).map(AtlasCard.recipe))
        cards.append(contentsOf: content.prefix(5).map(AtlasCard.content))

        let text: String
        if entities.isEmpty && recipes.isEmpty && content.isEmpty {
            text = "I do not have a local match for that. Try a different item name, or enable web search for community sources."
        } else if plan.shouldBrowseRecipes {
            if let kind = plan.recipeKind {
                text = "I found \(recipes.count) \(kind) recipes in the pinned Atlas snapshot."
            } else {
                text = "I found \(recipes.count) recipes in the pinned Atlas snapshot."
            }
        } else if plan.shouldBrowseEntities, let entityType = plan.entityType {
            text = "I found \(entities.count) \(Self.pluralName(for: entityType)) in the pinned Atlas snapshot."
        } else if let entity = entities.first {
            let used = recipes.filter { recipe in
                recipe.ingredients.contains {
                    $0.entityType == entity.entityType && $0.gameID == entity.gameID
                }
            }.count
            let produced = recipes.filter {
                $0.outputEntityType == entity.entityType && $0.outputGameID == entity.gameID
            }.count
            switch plan.goal {
            case .uses:
                text = "I found \(used) packed recipes that use \(entity.title)."
            case .recipe:
                if let operation = plan.operation {
                    text = "I found \(recipes.count) \(operation.rawValue) recipes related to \(entity.title)."
                } else {
                    text = "I found \(produced) packed recipes that make \(entity.title)."
                }
            case .lookup, .browseEntities, .browseRecipes:
                text = Self.lookupSummary(for: entity)
            }
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

    private func unique(_ entities: [Entity]) -> [Entity] {
        var seen: Set<String> = []
        return entities.filter { seen.insert($0.id).inserted }
    }

    private func unique(_ content: [ContentRecord]) -> [ContentRecord] {
        var seen: Set<String> = []
        return content.filter { seen.insert($0.id).inserted }
    }

    private static func lookupSummary(for entity: Entity) -> String {
        if let description = entity.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return "\(entity.title): \(description)"
        }
        if let subtitle = entity.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subtitle.isEmpty {
            return "\(entity.title) — \(subtitle)"
        }
        return "\(entity.title) is a \(entity.entityType) in the pinned Atlas snapshot."
    }

    private static func pluralName(for entityType: String) -> String {
        switch entityType {
        case "technology": return "technologies"
        case "substance": return "substances"
        default: return "products"
        }
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
    and label the web result as community/web. Answer in no more than two concise \
    sentences. Do not call a tool when the supplied evidence already answers the prompt.
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
            let response = try await session.respond(
                to: "\(prompt)\n\nGrounded local evidence:\n\(grounded)",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120)
            )
            return response.content
        } catch {
            return nil
        }
    }

    private static func groundedContext(_ local: AtlasReply) -> String {
        var evidence = ["deterministic summary: \(singleLine(local.text, limit: 700))"]
        evidence.append(contentsOf: local.cards.prefix(14).compactMap { card -> String? in
            switch card {
            case .entity(let entity):
                let details = [
                    entity.subtitle,
                    entity.description,
                    entity.category.map { "category \($0)" },
                    entity.rarity.map { "rarity \($0)" },
                    entity.baseValue.map { "base value \($0)" },
                ]
                    .compactMap { $0 }
                    .map { singleLine($0, limit: 400) }
                    .joined(separator: "; ")
                return "entity: \(entity.title) [\(entity.entityType)/\(entity.gameID)]\(details.isEmpty ? "" : "; \(details)")"
            case .recipe(let recipe):
                let ingredients = recipe.ingredients.prefix(8).map {
                    "\($0.title ?? $0.gameID)\($0.amount.map { " x\($0)" } ?? "")"
                }.joined(separator: ", ")
                let outputAmount = recipe.outputAmount.map { " x\($0)" } ?? ""
                return "recipe: \(recipe.recipeKind); \(recipe.title) -> \(recipe.outputTitle ?? recipe.outputGameID)\(outputAmount)\(ingredients.isEmpty ? "" : "; ingredients: \(ingredients)")"
            case .content(let record):
                return "content: \(record.dataset); \(record.title)"
            case .web: return nil
            }
        })
        return evidence.joined(separator: "\n")
    }

    private static func singleLine(_ value: String, limit: Int) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
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
        let rows = try store.recipesProducing(
            type: arguments.entityType,
            id: arguments.gameId,
            limit: 8
        )
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
        let rows = try store.recipesUsing(
            type: arguments.entityType,
            id: arguments.gameId,
            limit: 8
        )
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
