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
        let local = (try? gatherLocal(prompt: prompt)) ?? AtlasReply(
            text: "I could not search the local Atlas pack.",
            cards: [],
            note: nil
        )
        var cards = local.cards
        var notes: [String] = []

        if FoundationModelAvailability.current == .unavailable {
            notes.append("Atlas chat needs Apple Intelligence. Showing local search instead.")
        }

        if settings.liveAtlasEnabled {
            do {
                let live = try await LiveAtlasClient(settings: settings)
                    .searchEntities(query: prompt, type: nil)
                let liveCards = live.map(AtlasCard.entity)
                if !liveCards.isEmpty {
                    notes.append("Live Atlas results are labeled separately from the packed snapshot.")
                    cards.append(contentsOf: liveCards.filter { liveCard in
                        !cards.contains(where: { $0.id == liveCard.id })
                    })
                }
            } catch {
                notes.append("Live Atlas unavailable.")
            }
        }

        let wantsWeb = settings.webSearchEnabled && (
            prompt.localizedCaseInsensitiveContains("web")
                || prompt.localizedCaseInsensitiveContains("wiki")
                || prompt.localizedCaseInsensitiveContains("patch")
                || prompt.localizedCaseInsensitiveContains("expedition")
                || local.cards.isEmpty
        )
        if wantsWeb {
            do {
                let hits = try await WebSearchClient().search(query: prompt)
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

    private func gatherLocal(prompt: String) throws -> AtlasReply {
        let entities = try store.searchEntities(query: prompt, type: nil, limit: 8)
        var recipes: [Recipe] = []
        var content: [ContentRecord] = []
        if let first = entities.first {
            recipes.append(contentsOf: (try? store.recipesProducing(type: first.entityType, id: first.gameID)) ?? [])
            recipes.append(contentsOf: (try? store.recipesUsing(type: first.entityType, id: first.gameID)) ?? [])
        }
        content = (try? store.searchContent(query: prompt, dataset: nil, limit: 5)) ?? []

        var cards: [AtlasCard] = entities.map(AtlasCard.entity)
        cards.append(contentsOf: recipes.prefix(6).map(AtlasCard.recipe))
        cards.append(contentsOf: content.map(AtlasCard.content))

        let text: String
        if entities.isEmpty && recipes.isEmpty && content.isEmpty {
            text = "I do not have a local match for that. Try a different item name, or enable web search for community sources."
        } else if let entity = entities.first {
            let used = recipes.filter { $0.ingredients.contains { $0.gameID == entity.gameID } }.count
            let produced = recipes.filter { $0.outputGameID == entity.gameID }.count
            text = "\(entity.title) is a \(entity.entityType). Atlas has \(produced) recipe(s) that make it and \(used) recipe(s) that use it."
        } else {
            text = "I found \(cards.count) local result(s) in the pinned Atlas snapshot."
        }
        return AtlasReply(text: text, cards: unique(cards), note: nil)
    }

    private func foundationSpokenAnswer(prompt: String, local: AtlasReply) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return await FoundationModelsAtlas.run(prompt: prompt, local: local, store: store, settings: settings)
        }
        #endif
        return nil
    }

    private func unique(_ cards: [AtlasCard]) -> [AtlasCard] {
        var seen: Set<String> = []
        return cards.filter { seen.insert($0.id).inserted }
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
        store: SQLiteNMSStore,
        settings: AppSettings
    ) async -> String? {
        do {
            let grounded = groundedContext(local)
            let session = LanguageModelSession(
                tools: [
                    SearchEntitiesTool(store: store),
                    GetEntityTool(store: store),
                    RecipesForTool(store: store),
                    RecipesUsingTool(store: store),
                    SearchContentTool(store: store),
                ],
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
private func recipeJSON(_ recipe: Recipe) -> [String: String] {
    [
        "id": recipe.recipeID,
        "kind": recipe.recipeKind,
        "title": recipe.title,
        "output": recipe.outputGameID,
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
