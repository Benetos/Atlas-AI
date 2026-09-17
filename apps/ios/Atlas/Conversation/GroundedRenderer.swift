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
    var navigationDestination: AppDestination? = nil

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
        let planEvidence = recipePlanEvidence(in: claims)
        let records = presentedRecords(claims: claims, queryPlan: queryPlan, bundle: bundle, planEvidence: planEvidence)
        let entities = records.compactMap { record -> Entity? in
            if case .entity(let entity) = record.payload { return entity }
            return nil
        }
        let recipes = records.compactMap { record -> Recipe? in
            if case .recipe(let recipe) = record.payload { return recipe }
            return nil
        }
        let content = records.compactMap { record -> ContentRecord? in
            if case .content(let record) = record.payload { return record }
            return nil
        }
        let web = records.compactMap { record -> WebHit? in
            if case .web(let hit) = record.payload { return hit }
            return nil
        }

        var cards: [AtlasCard] = entities.prefix(ConversationBounds.answerEntityLimit).map(AtlasCard.entity)
        cards.append(contentsOf: recipes.prefix(ConversationBounds.answerRecipeLimit).map(AtlasCard.recipe))
        cards.append(contentsOf: content.prefix(ConversationBounds.answerContentLimit).map(AtlasCard.content))
        cards.append(contentsOf: web.map(AtlasCard.web))

        let text = factualText(
            claims: claims,
            queryPlan: queryPlan,
            entities: entities,
            recipes: recipes,
            cards: cards,
            planEvidence: planEvidence
        )
        var noteParts = notices
        if let planEvidence {
            noteParts.append(contentsOf: planNotes(for: planEvidence))
        }
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

        var seenIntents: Set<FollowUpIntent> = []
        let chips = followUps.filter { seenIntents.insert($0).inserted }.prefix(4).map { intent in
            ClarificationChip(id: intentChipID(intent), label: intent.chipLabel, intent: intent)
        }
        var seenNotes: Set<String> = []
        noteParts = noteParts.filter { !$0.isEmpty && seenNotes.insert($0).inserted }

        return (
            text,
            cards,
            noteParts.isEmpty ? nil : noteParts.joined(separator: " "),
            chips
        )
    }

    private func factualText(
        claims: [ValidatedClaim],
        queryPlan: AtlasQueryPlan,
        entities: [Entity],
        recipes: [Recipe],
        cards: [AtlasCard],
        planEvidence: DerivedEvidence?
    ) -> String {
        if claims.contains(where: { $0.kind == .packFailure }) {
            return "I could not read the installed Atlas pack."
        }
        if queryPlan.shouldBrowseSpecialist,
           let route = queryPlan.resolvedSpecialistRoute(matching: entities) {
            let summary = route.filterSummary
            if summary.isEmpty {
                return "I opened the packed \(route.feature.title.lowercased()) guide."
            }
            return "I opened the packed \(route.feature.title.lowercased()) guide for \(summary)."
        }
        if let planEvidence {
            return recipePlanText(for: planEvidence, target: entities.first)
        }
        if let quantity = claims.first(where: { $0.kind == .derivedTotal })?.facts.compactMap(\.quantity).first {
            return "The calculated total is \(quantity)."
        }
        if cards.isEmpty {
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
        if entities.count > 1, !entities.contains(where: { queryPlan.exactlyMatches($0) }) {
            return "I found a few matching items. Choose the one you mean."
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
            case .lookup, .browseEntities, .browseRecipes, .browseSpecialist:
                return Self.lookupSummary(for: entity)
            }
        }
        if let first = cards.first {
            switch first {
            case .content(let record):
                return "I found \(record.title) in the installed data."
            case .web:
                return "Here are the web sources I found for your question."
            case .entity, .recipe:
                break
            }
        }
        return "I found \(cards.count) local result(s) in the pinned Atlas snapshot."
    }

    private func recipePlanEvidence(in claims: [ValidatedClaim]) -> DerivedEvidence? {
        for claim in claims where claim.kind == .derivedTotal {
            for fact in claim.facts where fact.field == "output" && fact.quantity != nil {
                if let record = claim.records.first(where: { $0.evidenceID == fact.evidenceID }),
                   case .derived(let evidence) = record.payload,
                   evidence.engineName == ComputedRecipePlan.engineName {
                    return evidence
                }
            }
        }
        return nil
    }

    private func presentedRecords(
        claims: [ValidatedClaim],
        queryPlan: AtlasQueryPlan,
        bundle: EvidenceBundle,
        planEvidence: DerivedEvidence?
    ) -> [EvidenceRecord] {
        guard !claims.contains(where: { $0.kind == .packFailure }) else { return [] }
        let claimedRecords = claims.flatMap(\.records)
        let candidates: [EvidenceRecord]
        if let planEvidence {
            // Ingredient lookups and alternative recipes support the calculation; the
            // answer's card opens its target. The checklist presents its materials.
            candidates = (claimedRecords + bundle.records).filter { record in
                guard case .entity(let entity) = record.payload else { return false }
                return entity.id == planEvidence.normalizedInputs["target"]
            }
        } else if claims.contains(where: { $0.kind == .browseCount }),
                  queryPlan.shouldBrowseEntities || queryPlan.shouldBrowseRecipes {
            candidates = bundle.records.filter { record in
                switch record.payload {
                case .entity(let entity):
                    return queryPlan.shouldBrowseEntities
                        && (queryPlan.entityType == nil || queryPlan.entityType == entity.entityType)
                case .recipe(let recipe):
                    return queryPlan.shouldBrowseRecipes
                        && (queryPlan.recipeKind == nil || queryPlan.recipeKind == recipe.recipeKind)
                case .content, .web, .derived:
                    return false
                }
            } + claimedRecords.filter { record in
                if case .web = record.payload { return true }
                return false
            }
        } else {
            candidates = claimedRecords
        }

        // Deduplicate before category limits so repeated claims or source copies
        // cannot displace a distinct result or inflate the visible result count.
        var seenKeys: Set<RecordKey> = []
        return candidates.filter { seenKeys.insert($0.recordKey).inserted }
    }

    private func recipePlanText(for evidence: DerivedEvidence, target: Entity?) -> String {
        let inputs = evidence.normalizedInputs
        let title = target?.title ?? inputs["targetTitle"] ?? inputs["target"] ?? "this item"
        let quantity = evidence.output
        let rootKind = inputs["rootKind"]
        if rootKind == PlanNodeKind.missingRecipe.rawValue {
            return "I could not use the selected recipe for \(quantity)× \(title). Open the plan to choose another recipe."
        }
        if rootKind == PlanNodeKind.leaf.rawValue {
            if inputs["rootChoice"] == RecipeAlternative.gatherID {
                return "Gather \(quantity)× \(title) directly. This route has no crafting steps."
            }
            return "The installed data has no recipe for \(title). Obtain \(quantity)× \(title) directly; no ingredient breakdown is available."
        }
        let partial = inputs["truncated"] == "true" || (Int(inputs["cycleCount"] ?? "0") ?? 0) > 0
        let heading = "\(partial ? "Partial plan" : "Plan") for \(quantity)× \(title)"
        let lines = (inputs["checklistSummary"] ?? "").components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return "\(heading)\n\nNo ingredient checklist is available. Open the plan for details."
        }
        return "\(heading)\n\nGather:\n" + lines.map { "• \($0)" }.joined(separator: "\n")
    }

    private func planNotes(for evidence: DerivedEvidence) -> [String] {
        let inputs = evidence.normalizedInputs
        var notes = (inputs["notices"] ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        if inputs["truncated"] == "true" {
            notes.append("The ingredient breakdown stopped before every crafting step could be expanded. Some listed items may still be craftable.")
        }
        if (Int(inputs["cycleCount"] ?? "0") ?? 0) > 0 {
            notes.append("Some recipes loop back to an earlier ingredient. Those ingredients remain in the checklist; open the plan to choose another route.")
        }
        return notes
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
        case .openSpecialist(let route):
            return "specialist:\(route.feature.rawValue):\(route.filterSummary)"
        }
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
