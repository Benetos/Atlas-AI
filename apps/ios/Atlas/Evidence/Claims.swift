import Foundation

enum ClaimKind: String, Equatable, Sendable, Hashable, CaseIterable {
    case entityExists
    case entityDescription
    case recipeProduces
    case recipeUses
    case recipeRelated
    case browseCount
    case noMatch
    case derivedTotal
    case packFailure
}

struct FactRef: Equatable, Sendable, Hashable {
    var evidenceID: String
    var field: String
    var quantity: Int?
}

struct ProposedClaim: Equatable, Sendable, Hashable {
    var kindName: String
    var facts: [FactRef]

    var kind: ClaimKind? { ClaimKind(rawValue: kindName) }

    init(kind: ClaimKind, facts: [FactRef]) {
        self.kindName = kind.rawValue
        self.facts = facts
    }

    init(kindName: String, facts: [FactRef]) {
        self.kindName = kindName
        self.facts = facts
    }
}

enum FollowUpIntent: Equatable, Sendable, Hashable {
    case clarifyRecord(keys: [RecordKey])
    case requestExternalSource(ExternalSourceKind, query: String)
    case open(RecordKey)
    case usesFor(type: String, id: String)
    case recipesFor(type: String, id: String)
    case plan(type: String, id: String, quantity: Int)

    var chipLabel: String {
        switch self {
        case .clarifyRecord:
            return "Which one?"
        case .requestExternalSource(let source, _):
            return source == .web ? "Search the web" : "Search Live Atlas"
        case .open:
            return "Open"
        case .usesFor:
            return "What is it used in?"
        case .recipesFor:
            return "How do I make it?"
        case .plan(let _, let _, let quantity):
            return quantity == 1 ? "Open plan" : "Open \(quantity)× plan"
        }
    }
}

struct ClarificationChip: Equatable, Sendable, Hashable, Identifiable {
    var id: String
    var label: String
    var intent: FollowUpIntent
}

struct ProposedTurnPlan: Equatable, Sendable {
    var claims: [ProposedClaim]
    var followUps: [FollowUpIntent]
    var actions: [GeneratedActionProposal]
    var tone: String?

    static let empty = ProposedTurnPlan(claims: [], followUps: [], actions: [], tone: nil)
}

enum ClaimValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedKind(String)
    case unknownFact(String)
    case staleFact(String)
    case alteredQuantity(expected: Int, actual: Int)
    case invalidDerivedAncestry(String)
    case missingFact

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(let kind):
            return "Unsupported claim kind \(kind)."
        case .unknownFact:
            return "Claim referenced unknown evidence."
        case .staleFact:
            return "Claim referenced stale evidence."
        case .alteredQuantity:
            return "Claim quantity does not match evidence."
        case .invalidDerivedAncestry:
            return "Derived claim parents are invalid."
        case .missingFact:
            return "Claim is missing a required fact reference."
        }
    }
}

struct ValidatedClaim: Equatable, Sendable {
    var kind: ClaimKind
    var facts: [FactRef]
    var records: [EvidenceRecord]
}

struct ClaimValidator: Sendable {
    func validate(
        plan: ProposedTurnPlan,
        ledger: EvidenceLedger
    ) throws -> [ValidatedClaim] {
        try plan.claims.map { claim in
            try validate(claim: claim, ledger: ledger)
        }
    }

    func validate(claim: ProposedClaim, ledger: EvidenceLedger) throws -> ValidatedClaim {
        guard let kind = claim.kind else {
            throw ClaimValidationError.unsupportedKind(claim.kindName)
        }
        if kind != .noMatch && kind != .packFailure && claim.facts.isEmpty {
            throw ClaimValidationError.missingFact
        }
        var records: [EvidenceRecord] = []
        for fact in claim.facts {
            let record: EvidenceRecord
            do {
                record = try ledger.resolve(fact.evidenceID)
            } catch EvidenceError.unknownID {
                throw ClaimValidationError.unknownFact(fact.evidenceID)
            } catch EvidenceError.staleID {
                throw ClaimValidationError.staleFact(fact.evidenceID)
            } catch {
                throw ClaimValidationError.unknownFact(fact.evidenceID)
            }
            if let quantity = fact.quantity {
                try validateQuantity(quantity, fact: fact, record: record)
            }
            if case .derived(let derived) = record.payload {
                do {
                    try ledger.validateDerivedAncestry(derived)
                } catch {
                    throw ClaimValidationError.invalidDerivedAncestry(record.evidenceID)
                }
            }
            records.append(record)
        }
        return ValidatedClaim(kind: kind, facts: claim.facts, records: records)
    }

    private func validateQuantity(
        _ quantity: Int,
        fact: FactRef,
        record: EvidenceRecord
    ) throws {
        _ = try Quantity.checked(quantity)
        switch record.payload {
        case .derived(let derived):
            if let output = Int(derived.output), output != quantity {
                throw ClaimValidationError.alteredQuantity(expected: output, actual: quantity)
            }
        case .recipe(let recipe):
            if fact.field == "outputAmount",
               let raw = recipe.outputAmount,
               let expected = try? Quantity.parse(raw),
               expected != quantity {
                throw ClaimValidationError.alteredQuantity(expected: expected, actual: quantity)
            }
        default:
            break
        }
    }
}

protocol ProposedTurnPlanning: Sendable {
    func propose(
        prompt: String,
        queryPlan: AtlasQueryPlan,
        bundle: EvidenceBundle,
        ledger: EvidenceLedger
    ) async -> ProposedTurnPlan
}

struct DeterministicTurnPlanner: ProposedTurnPlanning {
    func propose(
        prompt: String,
        queryPlan: AtlasQueryPlan,
        bundle: EvidenceBundle,
        ledger: EvidenceLedger
    ) async -> ProposedTurnPlan {
        DeterministicTurnPlanner.plan(prompt: prompt, queryPlan: queryPlan, bundle: bundle)
    }

    static func plan(prompt: String, queryPlan: AtlasQueryPlan, bundle: EvidenceBundle) -> ProposedTurnPlan {
        let entities = bundle.records.filter { if case .entity = $0.payload { return true }; return false }
        let recipes = bundle.records.filter { if case .recipe = $0.payload { return true }; return false }
        let derived = bundle.records.filter { $0.isCalculated }

        if bundle.records.contains(where: { record in
            if case .derived(let evidence) = record.payload {
                return evidence.engineName == "pack-failure"
            }
            return false
        }) {
            return ProposedTurnPlan(
                claims: [ProposedClaim(kind: .packFailure, facts: [])],
                followUps: [],
                actions: [],
                tone: nil
            )
        }

        if entities.isEmpty && recipes.isEmpty && derived.isEmpty {
            var followUps: [FollowUpIntent] = []
            if queryPlan.requestsWeb {
                followUps.append(.requestExternalSource(.web, query: queryPlan.externalQuery))
            }
            if queryPlan.requestsLive {
                followUps.append(.requestExternalSource(.liveAtlas, query: queryPlan.externalQuery))
            }
            return ProposedTurnPlan(
                claims: [ProposedClaim(kind: .noMatch, facts: [])],
                followUps: followUps,
                actions: queryPlan.requestsWeb || queryPlan.requestsLive
                    ? [GeneratedActionProposal.requestExternal(from: queryPlan)]
                    : [],
                tone: nil
            )
        }

        var claims: [ProposedClaim] = []
        var actions: [GeneratedActionProposal] = []
        var followUps: [FollowUpIntent] = []

        if queryPlan.shouldBrowseRecipes || queryPlan.shouldBrowseEntities {
            if let first = (entities + recipes).first {
                claims.append(
                    ProposedClaim(
                        kind: .browseCount,
                        facts: [FactRef(evidenceID: first.evidenceID, field: "count", quantity: nil)]
                    )
                )
            }
        } else if let entityRecord = entities.first, case .entity(let entity) = entityRecord.payload {
            claims.append(
                ProposedClaim(
                    kind: .entityExists,
                    facts: [FactRef(evidenceID: entityRecord.evidenceID, field: "title")]
                )
            )
            if entity.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || entity.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                claims.append(
                    ProposedClaim(
                        kind: .entityDescription,
                        facts: [FactRef(evidenceID: entityRecord.evidenceID, field: "description")]
                    )
                )
            }
            switch queryPlan.goal {
            case .uses:
                claims.append(contentsOf: recipeClaims(kind: .recipeUses, recipes: recipes))
            case .recipe:
                if queryPlan.operation != nil {
                    claims.append(contentsOf: recipeClaims(kind: .recipeRelated, recipes: recipes))
                } else {
                    claims.append(contentsOf: recipeClaims(kind: .recipeProduces, recipes: recipes))
                }
            case .lookup, .browseEntities, .browseRecipes:
                break
            }
            actions.append(.open(entityRecord.recordKey))
            actions.append(.save(entityRecord.recordKey))
            followUps.append(.usesFor(type: entity.entityType, id: entity.gameID))
            followUps.append(.recipesFor(type: entity.entityType, id: entity.gameID))
            let planQuantity = RecipePlanIntent.quantity(from: prompt) ?? 1
            followUps.insert(
                .plan(type: entity.entityType, id: entity.gameID, quantity: planQuantity),
                at: RecipePlanIntent.quantity(from: prompt) == nil ? followUps.count : 0
            )
            actions.append(.plan(type: entity.entityType, id: entity.gameID, quantity: planQuantity))
        } else if let recipeRecord = recipes.first, case .recipe(let recipe) = recipeRecord.payload {
            claims.append(contentsOf: recipeClaims(kind: .recipeRelated, recipes: recipes))
            actions.append(.open(recipeRecord.recordKey))
            let planQuantity = RecipePlanIntent.quantity(from: prompt) ?? 1
            followUps.append(
                .plan(type: recipe.outputEntityType, id: recipe.outputGameID, quantity: planQuantity)
            )
            actions.append(
                .plan(type: recipe.outputEntityType, id: recipe.outputGameID, quantity: planQuantity)
            )
        }

        for record in derived {
            if case .derived(let evidence) = record.payload, let quantity = Int(evidence.output) {
                claims.append(
                    ProposedClaim(
                        kind: .derivedTotal,
                        facts: [FactRef(evidenceID: record.evidenceID, field: "output", quantity: quantity)]
                    )
                )
            }
        }

        if entities.count > 1 {
            followUps.insert(
                .clarifyRecord(keys: entities.prefix(4).map(\.recordKey)),
                at: 0
            )
        }

        if queryPlan.requestsWeb {
            actions.append(.requestExternal(from: queryPlan))
        }

        return ProposedTurnPlan(claims: claims, followUps: followUps, actions: actions, tone: nil)
    }

    private static func recipeClaims(kind: ClaimKind, recipes: [EvidenceRecord]) -> [ProposedClaim] {
        recipes.prefix(3).map { record in
            ProposedClaim(
                kind: kind,
                facts: [FactRef(evidenceID: record.evidenceID, field: "title")]
            )
        }
    }
}

struct FixedTurnPlanner: ProposedTurnPlanning {
    var plan: ProposedTurnPlan

    func propose(
        prompt: String,
        queryPlan: AtlasQueryPlan,
        bundle: EvidenceBundle,
        ledger: EvidenceLedger
    ) async -> ProposedTurnPlan {
        plan
    }
}
