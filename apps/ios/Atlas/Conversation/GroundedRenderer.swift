import Foundation

struct ValidatedAssistantTurn: Equatable, Sendable {
    var text: String
    var cards: [AtlasCard]
    var note: String?
    var followUps: [ClarificationChip]
    var allowedActions: [ResolvedAction]
    var pendingActions: [PendingAction]
    var notices: [String]
    var usedDeterministicFallback: Bool
    var packReleaseID: String
    var evidenceDigest: String
    var refreshRequired: Bool

    var atlasReply: AtlasReply {
        AtlasReply(
            text: text,
            cards: cards,
            note: note ?? (notices.isEmpty ? nil : notices.joined(separator: " "))
        )
    }
}

struct GroundedRenderer: Sendable {
    func render(
        claims: [ValidatedClaim],
        queryPlan: AtlasQueryPlan,
        bundle: EvidenceBundle,
        followUps: [FollowUpIntent],
        tone: String?,
        notices: [String],
        usedDeterministicFallback _: Bool
    ) -> (text: String, cards: [AtlasCard], note: String?, chips: [ClarificationChip]) {
        let entities = bundle.records.compactMap { record -> Entity? in
            if case .entity(let entity) = record.payload { return entity }
            return nil
        }
        let recipes = bundle.records.compactMap { record -> Recipe? in
            if case .recipe(let recipe) = record.payload { return recipe }
            return nil
        }
        let content = bundle.records.compactMap { record -> ContentRecord? in
            if case .content(let record) = record.payload { return record }
            return nil
        }
        let web = bundle.records.compactMap { record -> WebHit? in
            if case .web(let hit) = record.payload { return hit }
            return nil
        }

        var cards: [AtlasCard] = entities.prefix(ConversationBounds.answerEntityLimit).map(AtlasCard.entity)
        cards.append(contentsOf: recipes.prefix(ConversationBounds.answerRecipeLimit).map(AtlasCard.recipe))
        cards.append(contentsOf: content.prefix(ConversationBounds.answerContentLimit).map(AtlasCard.content))
        cards.append(contentsOf: web.map(AtlasCard.web))

        let text = factualText(claims: claims, queryPlan: queryPlan, entities: entities, recipes: recipes, cards: cards)
        var noteParts = notices
        if let tone, !tone.isEmpty {
            // Tone may color the note, never replace factual sentences.
            noteParts.append(tone)
        }
        let derivedNotes = claims.compactMap { claim -> String? in
            guard claim.kind == .derivedTotal else { return nil }
            return claim.records.compactMap { record -> String? in
                if case .derived(let derived) = record.payload {
                    return derived.provenanceLabel
                }
                return nil
            }.first
        }
        noteParts.append(contentsOf: derivedNotes)

        let chips = followUps.prefix(4).map { intent in
            ClarificationChip(id: intentChipID(intent), label: intent.chipLabel, intent: intent)
        }

        return (
            text,
            unique(cards),
            noteParts.isEmpty ? nil : noteParts.joined(separator: " "),
            chips
        )
    }

    private func factualText(
        claims: [ValidatedClaim],
        queryPlan: AtlasQueryPlan,
        entities: [Entity],
        recipes: [Recipe],
        cards: [AtlasCard]
    ) -> String {
        if claims.contains(where: { $0.kind == .packFailure }) {
            return "I could not read the installed Atlas pack."
        }
        if claims.contains(where: { $0.kind == .noMatch }) || (entities.isEmpty && recipes.isEmpty && cards.isEmpty) {
            return "I do not have a local match for that. Try a different item name, or enable web search for community sources."
        }
        if queryPlan.shouldBrowseRecipes {
            if let kind = queryPlan.recipeKind {
                return "I found \(recipes.count) \(kind) recipes in the pinned Atlas snapshot."
            }
            return "I found \(recipes.count) recipes in the pinned Atlas snapshot."
        }
        if queryPlan.shouldBrowseEntities, let entityType = queryPlan.entityType {
            return "I found \(entities.count) \(Self.pluralName(for: entityType)) in the pinned Atlas snapshot."
        }
        if let derived = claims.first(where: { $0.kind == .derivedTotal }),
           let fact = derived.facts.first,
           let quantity = fact.quantity,
           let record = derived.records.first,
           case .derived(let evidence) = record.payload {
            if let summary = evidence.normalizedInputs["checklistSummary"], !summary.isEmpty {
                return "\(evidence.engineName) calculated \(quantity) from the pinned Atlas snapshot. Gather \(summary)."
            }
            return "\(evidence.engineName) calculated \(quantity) from the pinned Atlas snapshot."
        }
        if let entity = entities.first {
            let used = recipes.filter { recipe in
                recipe.ingredients.contains {
                    $0.entityType == entity.entityType && $0.gameID == entity.gameID
                }
            }.count
            let produced = recipes.filter {
                $0.outputEntityType == entity.entityType && $0.outputGameID == entity.gameID
            }.count
            switch queryPlan.goal {
            case .uses:
                return "I found \(used) packed recipes that use \(entity.title)."
            case .recipe:
                if let operation = queryPlan.operation {
                    return "I found \(recipes.count) \(operation.rawValue) recipes related to \(entity.title)."
                }
                return "I found \(produced) packed recipes that make \(entity.title)."
            case .lookup, .browseEntities, .browseRecipes:
                return Self.lookupSummary(for: entity)
            }
        }
        return "I found \(cards.count) local result(s) in the pinned Atlas snapshot."
    }

    private func intentChipID(_ intent: FollowUpIntent) -> String {
        switch intent {
        case .clarifyRecord(let keys):
            return "clarify:\(keys.map(\.canonical).joined(separator: ","))"
        case .requestExternalSource(let source, let query):
            return "external:\(source.rawValue):\(query)"
        case .open(let key):
            return "open:\(key.canonical)"
        case .usesFor(let type, let id):
            return "uses:\(type):\(id)"
        case .recipesFor(let type, let id):
            return "recipes:\(type):\(id)"
        case .plan(let type, let id, let quantity):
            return "plan:\(type):\(id):\(quantity)"
        }
    }

    private func unique(_ cards: [AtlasCard]) -> [AtlasCard] {
        var seen: Set<String> = []
        return cards.filter { seen.insert($0.id).inserted }
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
