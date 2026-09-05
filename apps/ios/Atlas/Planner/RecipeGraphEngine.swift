import Foundation

protocol RecipeGraphSource: Sendable {
    func recipesProducing(type: String, id: String) async throws -> [Recipe]
    func entityTitle(type: String, id: String) async throws -> String
}

enum RecipeGraphError: Error, Equatable, LocalizedError, Sendable {
    case invalidOutputAmount(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidOutputAmount(let recipeID):
            return "Recipe \(recipeID) has no usable output amount."
        case .cancelled:
            return "Recipe planning was cancelled."
        case .failed(let message):
            return message
        }
    }
}

struct RecipeAlternative: Equatable, Sendable, Hashable, Identifiable {
    var recipeID: String
    var recipeKind: String
    var title: String
    var outputAmount: Int

    var id: String { recipeID }
}

struct NodeAlternatives: Equatable, Sendable, Hashable, Identifiable {
    var nodeID: String
    var title: String
    var recipes: [RecipeAlternative]

    var id: String { nodeID }
}

struct CycleNotice: Equatable, Sendable, Hashable, Codable {
    var nodeID: String
    var path: [String]
}

struct ChecklistLine: Equatable, Sendable, Hashable, Identifiable, Codable {
    var entityType: String
    var gameID: String
    var title: String
    var quantity: Int
    var isCycle: Bool
    var isTruncated: Bool

    var id: String { "leaf:\(entityType):\(gameID)" }
}

enum PlanNodeKind: String, Equatable, Sendable, Hashable {
    case crafted
    case leaf
    case cycle
    case truncated
    case missingRecipe
}

struct PlanNode: Equatable, Sendable, Hashable, Identifiable {
    var entityType: String
    var gameID: String
    var title: String
    var quantity: Int
    var kind: PlanNodeKind
    var selectedRecipeID: String?
    var outputPerCraft: Int?
    var crafts: Int?
    var children: [PlanNode]
    var pathID: String

    var id: String { pathID }
    var outlineChildren: [PlanNode]? { children.isEmpty ? nil : children }
}

struct ComputedRecipePlan: Equatable, Sendable {
    static let engineName = "recipe-graph"
    static let engineVersion = "1"

    var planID: String
    var packReleaseID: String
    var targetType: String
    var targetID: String
    var targetTitle: String
    var quantity: Int
    var selections: [String: String]
    var root: PlanNode
    var checklist: [ChecklistLine]
    var alternatives: [NodeAlternatives]
    var cycles: [CycleNotice]
    var notices: [String]
    var truncated: Bool
    var visitedNodes: Int
    var elapsedMilliseconds: Int
    var bounds: RecipeExpansionBounds

    var derivedEvidence: DerivedEvidence {
        DerivedEvidence.make(
            engineName: Self.engineName,
            engineVersion: Self.engineVersion,
            normalizedInputs: [
                "target": "\(targetType):\(targetID)",
                "quantity": String(quantity),
                "selections": selections.keys.sorted().map { "\($0)=\(selections[$0] ?? "")" }.joined(separator: ","),
                "checklist": checklist.map { "\($0.id)=\($0.quantity)" }.joined(separator: ";"),
                "checklistSummary": checklist.map { "\($0.quantity)× \($0.title)" }.joined(separator: "; "),
            ],
            bounds: bounds.asDictionary,
            parentEvidenceIDs: [],
            packReleaseID: packReleaseID,
            output: String(quantity)
        )
    }

    static func snapshot(from saved: SavedRecipePlan) -> ComputedRecipePlan {
        ComputedRecipePlan(
            planID: saved.planID,
            packReleaseID: saved.packReleaseID,
            targetType: saved.targetType,
            targetID: saved.targetID,
            targetTitle: saved.targetTitle,
            quantity: saved.quantity,
            selections: saved.selections,
            root: PlanNode(
                entityType: saved.targetType,
                gameID: saved.targetID,
                title: saved.title,
                quantity: saved.quantity,
                kind: .leaf,
                selectedRecipeID: nil,
                outputPerCraft: nil,
                crafts: nil,
                children: [],
                pathID: "saved:\(saved.id)"
            ),
            checklist: saved.checklist,
            alternatives: [],
            cycles: saved.cycles,
            notices: saved.notices + ["Pack or recipe data changed. Confirm to create a new revision."],
            truncated: saved.truncated,
            visitedNodes: 0,
            elapsedMilliseconds: 0,
            bounds: saved.bounds
        )
    }
}

extension NMSCatalog {
    func asRecipeGraphSource() -> CatalogRecipeGraphSource {
        CatalogRecipeGraphSource(catalog: self)
    }
}

struct CatalogRecipeGraphSource: RecipeGraphSource {
    var catalog: any NMSCatalog

    func recipesProducing(type: String, id: String) async throws -> [Recipe] {
        try await catalog.recipesProducing(type: type, id: id)
    }

    func entityTitle(type: String, id: String) async throws -> String {
        do {
            return try await catalog.entity(type: type, id: id).title
        } catch {
            return id
        }
    }
}

struct InMemoryRecipeGraphSource: RecipeGraphSource {
    var recipes: [Recipe]
    var titles: [String: String]
    var delayNanoseconds: UInt64 = 0

    func recipesProducing(type: String, id: String) async throws -> [Recipe] {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        return recipes.filter { $0.outputEntityType == type && $0.outputGameID == id }
    }

    func entityTitle(type: String, id: String) async throws -> String {
        titles["\(type):\(id)"] ?? id
    }
}

struct RecipeGraphEngine: Sendable {
    var bounds: RecipeExpansionBounds
    var clock: () -> TimeInterval

    init(
        bounds: RecipeExpansionBounds = .current,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.bounds = bounds
        self.clock = clock
    }

    func plan(
        targetType: String,
        targetID: String,
        quantity: Int,
        packReleaseID: String,
        source: any RecipeGraphSource,
        selections: [String: String] = [:]
    ) async throws -> ComputedRecipePlan {
        let quantity = try Quantity.checked(quantity)
        let started = clock()
        var state = ExpansionState(selections: selections)

        let title = try await source.entityTitle(type: targetType, id: targetID)
        let root = try await expand(
            type: targetType,
            id: targetID,
            title: title,
            quantity: quantity,
            path: [],
            depth: 0,
            source: source,
            started: started,
            state: &state
        )

        let elapsed = milliseconds(since: started)
        try bounds.rejectIfExceeded(
            depth: 0,
            nodes: state.visitedNodes,
            elapsedMilliseconds: elapsed
        )

        let checklist = state.leaves.values.sorted { $0.id < $1.id }
        let planID = EvidenceDigest.hex(
            [
                ComputedRecipePlan.engineName,
                ComputedRecipePlan.engineVersion,
                packReleaseID,
                targetType,
                targetID,
                String(quantity),
                state.selections.keys.sorted().map { "\($0)=\(state.selections[$0] ?? "")" }.joined(separator: ","),
                checklist.map { "\($0.id)=\($0.quantity)" }.joined(separator: ";"),
            ].joined(separator: "\u{1e}")
        )

        return ComputedRecipePlan(
            planID: planID,
            packReleaseID: packReleaseID,
            targetType: targetType,
            targetID: targetID,
            targetTitle: title,
            quantity: quantity,
            selections: state.selections,
            root: root,
            checklist: checklist,
            alternatives: state.alternatives.values.sorted { $0.nodeID < $1.nodeID },
            cycles: state.cycles,
            notices: state.notices,
            truncated: state.truncated,
            visitedNodes: state.visitedNodes,
            elapsedMilliseconds: elapsed,
            bounds: bounds
        )
    }

    private struct ExpansionState {
        var selections: [String: String]
        var alternatives: [String: NodeAlternatives] = [:]
        var leaves: [String: ChecklistLine] = [:]
        var cycles: [CycleNotice] = []
        var notices: [String] = []
        var truncated = false
        var visitedNodes = 0
    }

    private func expand(
        type: String,
        id: String,
        title: String,
        quantity: Int,
        path: [String],
        depth: Int,
        source: any RecipeGraphSource,
        started: TimeInterval,
        state: inout ExpansionState
    ) async throws -> PlanNode {
        try Task.checkCancellation()
        let elapsed = milliseconds(since: started)
        try bounds.rejectIfExceeded(depth: depth, nodes: state.visitedNodes + 1, elapsedMilliseconds: elapsed)

        state.visitedNodes += 1
        let nodeID = "entity:\(type):\(id)"
        let pathID = (path + [nodeID]).joined(separator: ">")

        if path.contains(nodeID) {
            state.cycles.append(CycleNotice(nodeID: nodeID, path: path + [nodeID]))
            try addLeaf(
                type: type,
                id: id,
                title: title,
                quantity: quantity,
                isCycle: true,
                isTruncated: false,
                state: &state
            )
            return PlanNode(
                entityType: type,
                gameID: id,
                title: title,
                quantity: quantity,
                kind: .cycle,
                selectedRecipeID: nil,
                outputPerCraft: nil,
                crafts: nil,
                children: [],
                pathID: pathID
            )
        }

        if depth >= bounds.depth {
            state.truncated = true
            state.notices.append("Stopped expanding \(title) at depth \(depth).")
            try addLeaf(
                type: type,
                id: id,
                title: title,
                quantity: quantity,
                isCycle: false,
                isTruncated: true,
                state: &state
            )
            return PlanNode(
                entityType: type,
                gameID: id,
                title: title,
                quantity: quantity,
                kind: .truncated,
                selectedRecipeID: nil,
                outputPerCraft: nil,
                crafts: nil,
                children: [],
                pathID: pathID
            )
        }

        let producing = try await limitedAlternatives(type: type, id: id, source: source)
        if producing.isEmpty {
            try addLeaf(
                type: type,
                id: id,
                title: title,
                quantity: quantity,
                isCycle: false,
                isTruncated: false,
                state: &state
            )
            return PlanNode(
                entityType: type,
                gameID: id,
                title: title,
                quantity: quantity,
                kind: .leaf,
                selectedRecipeID: nil,
                outputPerCraft: nil,
                crafts: nil,
                children: [],
                pathID: pathID
            )
        }

        let alts = producing.map { recipe in
            RecipeAlternative(
                recipeID: recipe.recipeID,
                recipeKind: recipe.recipeKind,
                title: recipe.title,
                outputAmount: Self.parseAmount(recipe.outputAmount).value
            )
        }
        state.alternatives[nodeID] = NodeAlternatives(nodeID: nodeID, title: title, recipes: alts)

        let selectedID = state.selections[nodeID] ?? producing[0].recipeID
        state.selections[nodeID] = selectedID
        guard let recipe = producing.first(where: { $0.recipeID == selectedID }) else {
            state.notices.append("Selected recipe is not in this snapshot.")
            try addLeaf(
                type: type,
                id: id,
                title: title,
                quantity: quantity,
                isCycle: false,
                isTruncated: false,
                state: &state
            )
            return PlanNode(
                entityType: type,
                gameID: id,
                title: title,
                quantity: quantity,
                kind: .missingRecipe,
                selectedRecipeID: selectedID,
                outputPerCraft: nil,
                crafts: nil,
                children: [],
                pathID: pathID
            )
        }

        let parsedOutput = Self.parseAmount(recipe.outputAmount)
        if let warning = parsedOutput.warning {
            state.notices.append("\(recipe.title): \(warning)")
        }
        guard parsedOutput.value >= 1 else {
            throw RecipeGraphError.invalidOutputAmount(recipe.recipeID)
        }

        let crafts = try Self.craftsNeeded(quantity: quantity, outputPerCraft: parsedOutput.value)
        var children: [PlanNode] = []
        for ingredient in recipe.ingredients.sorted(by: { $0.position < $1.position }) {
            let parsedIngredient = Self.parseAmount(ingredient.amount)
            if let warning = parsedIngredient.warning {
                state.notices.append("\(ingredient.title ?? ingredient.gameID): \(warning)")
            }
            let needed = try Quantity.product(parsedIngredient.value, crafts)
            let childTitle = try await source.entityTitle(type: ingredient.entityType, id: ingredient.gameID)
            let child = try await expand(
                type: ingredient.entityType,
                id: ingredient.gameID,
                title: childTitle,
                quantity: needed,
                path: path + [nodeID],
                depth: depth + 1,
                source: source,
                started: started,
                state: &state
            )
            children.append(child)
        }

        return PlanNode(
            entityType: type,
            gameID: id,
            title: title,
            quantity: quantity,
            kind: .crafted,
            selectedRecipeID: recipe.recipeID,
            outputPerCraft: parsedOutput.value,
            crafts: crafts,
            children: children,
            pathID: pathID
        )
    }

    private func limitedAlternatives(
        type: String,
        id: String,
        source: any RecipeGraphSource
    ) async throws -> [Recipe] {
        let rows = try await source.recipesProducing(type: type, id: id)
        let unique = Dictionary(grouping: rows, by: \.recipeID).compactMap { $0.value.first }
        return Array(
            unique.sorted { $0.recipeID < $1.recipeID }.prefix(bounds.alternativesPerNode)
        )
    }

    private func addLeaf(
        type: String,
        id: String,
        title: String,
        quantity: Int,
        isCycle: Bool,
        isTruncated: Bool,
        state: inout ExpansionState
    ) throws {
        let key = "leaf:\(type):\(id)"
        if var existing = state.leaves[key] {
            existing.quantity = try Quantity.sum(existing.quantity, quantity)
            existing.isCycle = existing.isCycle || isCycle
            existing.isTruncated = existing.isTruncated || isTruncated
            state.leaves[key] = existing
        } else {
            state.leaves[key] = ChecklistLine(
                entityType: type,
                gameID: id,
                title: title,
                quantity: quantity,
                isCycle: isCycle,
                isTruncated: isTruncated
            )
        }
    }

    private func milliseconds(since started: TimeInterval) -> Int {
        Int(((clock() - started) * 1000).rounded(.down))
    }

    static func craftsNeeded(quantity: Int, outputPerCraft: Int) throws -> Int {
        let need = try Quantity.checked(quantity)
        let output = try Quantity.checked(outputPerCraft)
        let (summed, overflow) = need.addingReportingOverflow(output - 1)
        guard !overflow else { throw ConversationBoundError.quantityOverflow }
        let (result, divided) = summed.dividedReportingOverflow(by: output)
        guard !divided else { throw ConversationBoundError.quantityOverflow }
        return try Quantity.checked(max(result, 1))
    }

    static func parseAmount(_ raw: String?) -> (value: Int, warning: String?) {
        guard let raw else { return (1, nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (1, nil) }
        if let value = Int(trimmed) {
            if value >= 1 { return (value, nil) }
            return (1, "amount \(trimmed) is not a usable whole number; treated as 1")
        }
        return (1, "amount \(trimmed) is not a whole number; treated as 1")
    }
}
