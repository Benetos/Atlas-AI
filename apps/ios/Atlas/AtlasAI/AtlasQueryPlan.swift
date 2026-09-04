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
        case browseEntities
        case browseRecipes
    }

    let originalPrompt: String
    let source: Source
    let operation: Operation?
    let goal: Goal
    let entityType: String?
    let localQuery: String?
    let externalQuery: String

    var recipeKind: String? { operation?.rawValue }
    var requestsWeb: Bool { source == .web }
    var requestsLive: Bool { source == .live }

    var shouldSearchRecipes: Bool {
        operation != nil || goal == .recipe || goal == .uses || goal == .browseRecipes
    }

    var shouldBrowseRecipes: Bool {
        goal == .browseRecipes
    }

    var shouldBrowseEntities: Bool { goal == .browseEntities }

    /// FTS5 intentionally uses strict AND matching. Keep that precision first,
    /// then try a conservative singular form so natural prompts such as
    /// "warp cells" can still find an item named "Warp Cell".
    var localSearchQueries: [String] {
        guard let localQuery else { return [] }
        let singular = Self.tokens(in: localQuery)
            .map(Self.singularized)
            .joined(separator: " ")
        return singular == localQuery.lowercased() ? [localQuery] : [localQuery, singular]
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
        let candidateTokens = Self.tokens(in: withoutDomain)
        let resolvedEntityType = Self.entityType(for: candidateTokens.map { $0.lowercased() })
        entityType = resolvedEntityType
        let dropQuantityToken = RecipePlanIntent.quantity(from: normalized) != nil
        let searchableTokens = candidateTokens.filter { token in
            if dropQuantityToken, Int(token) != nil {
                return false
            }
            if let resolvedEntityType,
               Self.entityTypeTerms[resolvedEntityType]?.contains(token.lowercased()) == true {
                return false
            }
            return !Self.localGlue.contains(token.lowercased())
        }
        let searchableLower = searchableTokens.map { $0.lowercased() }
        localQuery = searchableTokens.isEmpty ? nil : searchableTokens.joined(separator: " ")

        let recipeLanguage = !Set(lowerTokens).isDisjoint(with: Self.recipeTerms)
        let usesLanguage = lowerPrompt.contains("used in")
            || lowerPrompt.contains("use this")
            || lowerPrompt.contains("uses this")
            || (lowerTokens.first == "what" && lowerTokens.last == "for")
            || lowerTokens.contains("uses")

        let broadRecipeQuery = recipeLanguage && (
            searchableLower.isEmpty
                || Set(searchableLower).isSubset(of: Self.broadRecipeTerms)
        )
        let broadEntityQuery = resolvedEntityType != nil && searchableLower.isEmpty

        if broadRecipeQuery {
            goal = .browseRecipes
        } else if usesLanguage {
            goal = .uses
        } else if operation != nil || recipeLanguage {
            goal = .recipe
        } else if broadEntityQuery {
            goal = .browseEntities
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
        "all", "any", "everything", "food", "foods", "item", "items",
        "something", "stuff", "thing", "things",
    ]

    private static let entityTypeTerms: [String: Set<String>] = [
        "product": ["product", "products"],
        "substance": ["substance", "substances"],
        "technology": ["tech", "technologies", "technology"],
    ]

    /// Words that express the question rather than identify NMS data. Operation
    /// words are removed because their typed meaning is retained separately.
    private static let localGlue: Set<String> = [
        "a", "about", "all", "an", "and", "any", "are", "atlas", "can", "could",
        "build", "built", "create", "created", "craft", "crafted", "crafting",
        "do", "does", "everything", "find", "for", "from", "get", "give", "how",
        "i", "in", "ingredient", "ingredients", "internet", "into", "is", "locate",
        "latest", "live", "look", "lookup", "made", "make", "making", "me",
        "my", "need", "newest", "now", "obtain", "of", "on", "online", "please",
        "produce", "produced", "recent",
        "recipe", "recipes", "refine", "refined", "refiner", "refining", "search",
        "show", "tell", "the", "this", "to", "today", "up", "use", "used",
        "uses", "using", "web", "what", "where", "which", "wiki", "with", "would", "you",
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

    private static func entityType(for tokens: [String]) -> String? {
        let meaningful = tokens.filter { !localGlue.contains($0) }
        for type in ["product", "substance", "technology"] {
            guard let terms = entityTypeTerms[type],
                  let matched = meaningful.first(where: terms.contains)
            else { continue }

            // Plural category names are unambiguous. Treat a singular category
            // as browsing only when it is the entire remaining subject, so an
            // item such as "Salvaged Technology Data" stays an item lookup.
            if matched.hasSuffix("s") || matched == "tech" || meaningful == [matched] {
                return type
            }
        }
        return nil
    }

    private static func singularized(_ token: String) -> String {
        let value = token.lowercased()
        guard value.count > 3 else { return value }
        if value.hasSuffix("ies"), value.count > 4 {
            return String(value.dropLast(3)) + "y"
        }
        if value.hasSuffix("ches") || value.hasSuffix("shes") || value.hasSuffix("xes") {
            return String(value.dropLast(2))
        }
        if value.hasSuffix("s"),
           !value.hasSuffix("ss"),
           !value.hasSuffix("us"),
           !value.hasSuffix("is") {
            return String(value.dropLast())
        }
        return value
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
