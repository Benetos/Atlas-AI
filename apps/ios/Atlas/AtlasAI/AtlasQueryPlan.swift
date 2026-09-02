import Foundation

/// A deterministic interpretation of one Atlas composer prompt.
///
/// The language model can improve the spoken response, but local retrieval must
/// also work when Apple Intelligence is unavailable. This planner removes
/// conversational and operation words before the query reaches strict FTS5.
struct AtlasQueryPlan: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case local
        case live
        case web
    }

    enum Operation: String, Equatable, Sendable {
        case crafting
        case refining
        case cooking
    }

    enum Goal: Equatable, Sendable {
        case lookup
        case recipe
        case uses
        case browseRecipes
    }

    let originalPrompt: String
    let source: Source
    let operation: Operation?
    let goal: Goal
    let localQuery: String?
    let externalQuery: String

    var recipeKind: String? { operation?.rawValue }
    var requestsWeb: Bool { source == .web }
    var requestsLive: Bool { source == .live }

    var shouldSearchRecipes: Bool {
        operation != nil || goal == .recipe || goal == .uses || goal == .browseRecipes
    }

    var shouldBrowseRecipes: Bool {
        goal == .browseRecipes && operation != nil
    }

    func matchesIntendedKind(_ recipeKind: String) -> Bool {
        operation == nil || operation?.rawValue == recipeKind
    }

    init(prompt: String) {
        let normalized = Self.collapsedWhitespace(prompt)
        let lowerPrompt = normalized.lowercased()
        let promptTokens = Self.tokens(in: normalized)
        let lowerTokens = promptTokens.map { $0.lowercased() }

        originalPrompt = normalized
        source = Self.source(for: lowerPrompt, tokens: lowerTokens)
        operation = Self.operation(for: lowerTokens)

        let external = Self.removingDirectivePhrases(from: normalized)
        externalQuery = external.isEmpty ? normalized : external

        let withoutDomain = Self.removingGameName(from: external)
        let searchableTokens = Self.tokens(in: withoutDomain).filter { token in
            !Self.localGlue.contains(token.lowercased())
        }
        let searchableLower = searchableTokens.map { $0.lowercased() }
        localQuery = searchableTokens.isEmpty ? nil : searchableTokens.joined(separator: " ")

        let recipeLanguage = !Set(lowerTokens).isDisjoint(with: Self.recipeTerms)
        let usesLanguage = lowerPrompt.contains("used in")
            || lowerPrompt.contains("use this")
            || lowerPrompt.contains("uses this")
            || (lowerTokens.first == "what" && lowerTokens.last == "for")
            || lowerTokens.contains("uses")

        let broadRecipeQuery = operation != nil && (
            searchableLower.isEmpty
                || Set(searchableLower).isSubset(of: Self.broadRecipeTerms)
        )

        if broadRecipeQuery {
            goal = .browseRecipes
        } else if usesLanguage {
            goal = .uses
        } else if operation != nil || recipeLanguage {
            goal = .recipe
        } else {
            goal = .lookup
        }
    }

    private static let operationTerms: [(Operation, Set<String>)] = [
        (.crafting, ["craft", "crafted", "crafting"]),
        (.refining, ["refine", "refined", "refiner", "refining"]),
        (.cooking, ["cook", "cooked", "cooking"]),
    ]

    private static let recipeTerms: Set<String> = [
        "craft", "crafted", "crafting",
        "ingredient", "ingredients",
        "make", "made", "making",
        "recipe", "recipes",
        "refine", "refined", "refiner", "refining",
        "cook", "cooked", "cooking",
    ]

    private static let broadRecipeTerms: Set<String> = [
        "food", "foods", "item", "items", "something", "stuff", "thing", "things",
    ]

    /// Words that express the question rather than identify NMS data. Operation
    /// words are removed because their typed meaning is retained separately.
    private static let localGlue: Set<String> = [
        "a", "about", "an", "and", "are", "atlas", "can", "could",
        "craft", "crafted", "crafting", "do", "does", "for", "from", "get",
        "give", "how", "i", "in", "ingredient", "ingredients", "internet", "is",
        "latest", "live", "look", "lookup", "made", "make", "making", "me",
        "my", "newest", "now", "of", "on", "online", "please", "recent",
        "recipe", "recipes", "refine", "refined", "refiner", "refining", "search",
        "show", "tell", "the", "this", "to", "today", "up", "use", "used",
        "uses", "web", "what", "where", "which", "wiki", "with", "would", "you",
        "cook", "cooked", "cooking", "current",
    ]

    private static let directivePhrases = [
        "search the internet for",
        "search the web for",
        "search live atlas for",
        "look on the web for",
        "search online for",
        "look up online",
        "ask the web",
        "search live atlas",
        "live atlas",
    ]

    private static func source(for lowerPrompt: String, tokens: [String]) -> Source {
        let tokenSet = Set(tokens)
        let explicitlyWeb = !tokenSet.isDisjoint(with: ["web", "wiki", "online", "internet"])
        let currentLanguage = !tokenSet.isDisjoint(
            with: ["active", "current", "latest", "newest", "now", "recent", "today"]
        )
        let timeSensitiveSubject = !tokenSet.isDisjoint(
            with: ["expedition", "expeditions", "patch", "patches", "update", "updates"]
        )
        if explicitlyWeb || tokenSet.contains("patch") || (currentLanguage && timeSensitiveSubject) {
            return .web
        }
        // Remote database retrieval requires the explicit product phrase. A
        // generic word such as "live" must never cause a query to leave the device.
        if lowerPrompt.contains("live atlas") {
            return .live
        }
        return .local
    }

    private static func operation(for tokens: [String]) -> Operation? {
        var best: (index: Int, operation: Operation)?
        for (operation, terms) in operationTerms {
            guard let index = tokens.firstIndex(where: terms.contains) else { continue }
            if best == nil || index < best!.index {
                best = (index, operation)
            }
        }
        return best?.operation
    }

    private static func removingDirectivePhrases(from prompt: String) -> String {
        var result = prompt
        for phrase in directivePhrases {
            while let range = result.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.removeSubrange(range)
            }
        }
        return collapsedWhitespace(result)
    }

    private static func removingGameName(from prompt: String) -> String {
        var result = prompt
        for phrase in ["No Man's Sky", "No Man’s Sky"] {
            while let range = result.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.removeSubrange(range)
            }
        }
        return collapsedWhitespace(result)
    }

    private static func tokens(in value: String) -> [String] {
        value.split { character in
            !character.isLetter && !character.isNumber && character != "_" && character != "-"
        }.map(String.init)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
