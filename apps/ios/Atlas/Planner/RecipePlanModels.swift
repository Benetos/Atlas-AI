import Foundation

struct RecipePlanIntent: Equatable, Sendable {
    var quantity: Int

    static func quantity(from prompt: String) -> Int? {
        let tokens = prompt.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
        let triggers: Set<String> = ["need", "make", "craft", "plan", "want"]
        let connectors: Set<String> = ["for", "of", "me", "a", "an", "to"]
        for index in tokens.indices {
            guard triggers.contains(tokens[index]), index + 1 < tokens.endIndex else { continue }
            for candidate in tokens[(index + 1)...].prefix(4) {
                if connectors.contains(candidate) { continue }
                if let value = Int(candidate), ConversationBounds.quantityRange.contains(value) {
                    return value
                }
                break
            }
        }
        return nil
    }
}

struct SavedRecipePlan: Equatable, Sendable, Identifiable, Hashable, Codable {
    var id: String
    var revision: Int
    var predecessorID: String?
    var title: String
    var targetTitle: String
    var targetType: String
    var targetID: String
    var quantity: Int
    var selections: [String: String]
    var checklist: [ChecklistLine]
    var notices: [String]
    var cycles: [CycleNotice]
    var truncated: Bool
    var progress: [String: Bool]
    var engineVersion: String
    var bounds: RecipeExpansionBounds
    var packReleaseID: String
    var planID: String
    var createdAt: Date
    var updatedAt: Date

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var destination: AppDestination {
        .recipePlan(type: targetType, id: targetID, quantity: quantity, artifactID: id)
    }

    var checkedCount: Int {
        checklist.filter { progress[$0.id] == true }.count
    }

    static func from(
        plan: ComputedRecipePlan,
        id: String,
        revision: Int,
        predecessorID: String?,
        progress: [String: Bool],
        now: Date
    ) -> SavedRecipePlan {
        SavedRecipePlan(
            id: id,
            revision: revision,
            predecessorID: predecessorID,
            title: "\(plan.quantity)× \(plan.targetTitle)",
            targetTitle: plan.targetTitle,
            targetType: plan.targetType,
            targetID: plan.targetID,
            quantity: plan.quantity,
            selections: plan.selections,
            checklist: plan.checklist,
            notices: plan.notices,
            cycles: plan.cycles,
            truncated: plan.truncated,
            progress: Self.transferredProgress(from: progress, onto: plan.checklist),
            engineVersion: ComputedRecipePlan.engineVersion,
            bounds: plan.bounds,
            packReleaseID: plan.packReleaseID,
            planID: plan.planID,
            createdAt: now,
            updatedAt: now
        )
    }

    static func transferredProgress(
        from previous: [String: Bool],
        onto checklist: [ChecklistLine]
    ) -> [String: Bool] {
        var transferred: [String: Bool] = [:]
        for line in checklist {
            if previous[line.id] == true {
                transferred[line.id] = true
            }
        }
        return transferred
    }
}

struct RecipePlanRecomputeDiff: Equatable, Sendable {
    var missingLineIDs: [String]
    var newLineIDs: [String]
    var changedQuantities: [String: (was: Int, now: Int)]
    var packChanged: Bool
    var engineChanged: Bool
    var recipeMissing: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.missingLineIDs == rhs.missingLineIDs
            && lhs.newLineIDs == rhs.newLineIDs
            && lhs.packChanged == rhs.packChanged
            && lhs.engineChanged == rhs.engineChanged
            && lhs.recipeMissing == rhs.recipeMissing
            && lhs.changedQuantities.count == rhs.changedQuantities.count
            && lhs.changedQuantities.allSatisfy { key, value in
                guard let other = rhs.changedQuantities[key] else { return false }
                return value.was == other.was && value.now == other.now
            }
    }

    var hasChanges: Bool {
        packChanged || engineChanged || recipeMissing
            || !missingLineIDs.isEmpty || !newLineIDs.isEmpty || !changedQuantities.isEmpty
    }

    static func compare(saved: SavedRecipePlan, computed: ComputedRecipePlan) -> RecipePlanRecomputeDiff {
        let oldIDs = Set(saved.checklist.map(\.id))
        let newIDs = Set(computed.checklist.map(\.id))
        var changed: [String: (was: Int, now: Int)] = [:]
        for line in computed.checklist {
            if let old = saved.checklist.first(where: { $0.id == line.id }), old.quantity != line.quantity {
                changed[line.id] = (old.quantity, line.quantity)
            }
        }
        return RecipePlanRecomputeDiff(
            missingLineIDs: saved.checklist.map(\.id).filter { !newIDs.contains($0) },
            newLineIDs: computed.checklist.map(\.id).filter { !oldIDs.contains($0) },
            changedQuantities: changed,
            packChanged: saved.packReleaseID != computed.packReleaseID,
            engineChanged: saved.engineVersion != ComputedRecipePlan.engineVersion,
            recipeMissing: computed.root.kind == .missingRecipe
        )
    }
}
