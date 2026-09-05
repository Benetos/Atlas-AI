import Foundation

protocol PureCalculationTool: Sendable {
    var name: String { get }
    var version: String { get }
}

/// Composes database tools with explicitly approved pure calculation tools.
/// Must not depend on network clients, saved repositories, routers, or action executors.
struct LocalKnowledgeToolRegistry: Sendable {
    var database: LocalDatabaseToolRegistry
    var calculationToolNames: [String]

    init(database: LocalDatabaseToolRegistry, calculationToolNames: [String] = ["scale_quantity", "plan_recipe", "compare_recipe_paths"]) {
        self.database = database
        self.calculationToolNames = calculationToolNames
    }

    func beginTurn() {
        database.beginTurn()
    }

    func invoke(_ call: LocalToolCall) async throws -> LocalToolOutput {
        switch call.name {
        case "scale_quantity":
            return scaleQuantity(call)
        case "plan_recipe":
            return try await planRecipe(call)
        case "compare_recipe_paths":
            return try await compareRecipePaths(call)
        default:
            return try await database.invoke(call)
        }
    }

    func scaleQuantity(
        quantity: Int,
        multiplier: Int,
        parentEvidenceIDs: [String],
        ledger: EvidenceLedger,
        packIdentity: PackIdentity
    ) throws -> DerivedEvidence {
        let total = try Quantity.product(quantity, multiplier)
        for parent in parentEvidenceIDs {
            _ = try ledger.resolve(parent)
        }
        let derived = DerivedEvidence.make(
            engineName: "scale_quantity",
            engineVersion: "1",
            normalizedInputs: [
                "quantity": String(quantity),
                "multiplier": String(multiplier),
            ],
            parentEvidenceIDs: parentEvidenceIDs,
            packReleaseID: packIdentity.sourceCommitSHA,
            output: String(total)
        )
        return derived
    }

    private func scaleQuantity(_ call: LocalToolCall) -> LocalToolOutput {
        let quantity = Int(call.query ?? "") ?? 0
        let multiplier = call.limit ?? 1
        do {
            let derived = try scaleQuantity(
                quantity: quantity,
                multiplier: multiplier,
                parentEvidenceIDs: [],
                ledger: database.ledger,
                packIdentity: database.packIdentity
            )
            let issued = database.ledger.issue(payload: .derived(derived), source: .calculated)
            return LocalToolOutput(
                name: call.name,
                status: .ok,
                evidenceIDs: [issued.evidenceID],
                packReleaseID: database.packIdentity.sourceCommitSHA,
                sourceSHA: database.packIdentity.sourceCommitSHA,
                payload: .message(derived.output),
                notice: derived.provenanceLabel
            )
        } catch {
            return LocalToolOutput(
                name: call.name,
                status: .rejected,
                evidenceIDs: [],
                packReleaseID: database.packIdentity.sourceCommitSHA,
                sourceSHA: database.packIdentity.sourceCommitSHA,
                payload: .message(error.localizedDescription),
                notice: error.localizedDescription
            )
        }
    }

    private func planRecipe(_ call: LocalToolCall) async throws -> LocalToolOutput {
        guard let type = call.entityType, let id = call.gameID, !type.isEmpty, !id.isEmpty else {
            return rejected(name: call.name, message: "Missing entity identity")
        }
        let rawQuantity = call.quantity.map(String.init) ?? call.query ?? "1"
        do {
            try Task.checkCancellation()
            let quantity = try Quantity.parse(rawQuantity)
            let plan = try await RecipeGraphEngine().plan(
                targetType: type,
                targetID: id,
                quantity: quantity,
                packReleaseID: database.packIdentity.sourceCommitSHA,
                source: database.catalog.asRecipeGraphSource()
            )
            try Task.checkCancellation()
            let issued = database.ledger.issue(payload: .derived(plan.derivedEvidence), source: .calculated)
            let summary = plan.checklist
                .map { "\($0.quantity)× \($0.title)" }
                .joined(separator: "; ")
            return LocalToolOutput(
                name: call.name,
                status: .ok,
                evidenceIDs: [issued.evidenceID],
                packReleaseID: database.packIdentity.sourceCommitSHA,
                sourceSHA: database.packIdentity.sourceCommitSHA,
                payload: .message(summary.isEmpty ? String(quantity) : summary),
                notice: plan.derivedEvidence.provenanceLabel
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return rejected(name: call.name, message: error.localizedDescription)
        }
    }

    private func compareRecipePaths(_ call: LocalToolCall) async throws -> LocalToolOutput {
        guard let type = call.entityType, let id = call.gameID, !type.isEmpty, !id.isEmpty else {
            return rejected(name: call.name, message: "Missing entity identity")
        }
        guard let firstID = call.recipeID, !firstID.isEmpty,
              let secondID = call.query, !secondID.isEmpty, firstID != secondID
        else {
            return rejected(name: call.name, message: "Compare needs two different recipe IDs.")
        }
        let rawQuantity = call.quantity.map(String.init) ?? "1"
        do {
            try Task.checkCancellation()
            let quantity = try Quantity.parse(rawQuantity)
            let nodeID = "entity:\(type):\(id)"
            let source = database.catalog.asRecipeGraphSource()
            let first = try await RecipeGraphEngine().plan(
                targetType: type,
                targetID: id,
                quantity: quantity,
                packReleaseID: database.packIdentity.sourceCommitSHA,
                source: source,
                selections: [nodeID: firstID]
            )
            try Task.checkCancellation()
            let second = try await RecipeGraphEngine().plan(
                targetType: type,
                targetID: id,
                quantity: quantity,
                packReleaseID: database.packIdentity.sourceCommitSHA,
                source: source,
                selections: [nodeID: secondID]
            )
            try Task.checkCancellation()
            let issuedFirst = database.ledger.issue(payload: .derived(first.derivedEvidence), source: .calculated)
            let issuedSecond = database.ledger.issue(payload: .derived(second.derivedEvidence), source: .calculated)
            let firstIDs = Set(first.checklist.map(\.id))
            let secondIDs = Set(second.checklist.map(\.id))
            let onlyFirst = first.checklist.filter { !secondIDs.contains($0.id) }
                .map { "\($0.quantity)× \($0.title)" }
            let onlySecond = second.checklist.filter { !firstIDs.contains($0.id) }
                .map { "\($0.quantity)× \($0.title)" }
            let summary = [
                "Path \(firstID): " + first.checklist.map { "\($0.quantity)× \($0.title)" }.joined(separator: ", "),
                "Path \(secondID): " + second.checklist.map { "\($0.quantity)× \($0.title)" }.joined(separator: ", "),
                onlyFirst.isEmpty ? nil : "Only in first: " + onlyFirst.joined(separator: ", "),
                onlySecond.isEmpty ? nil : "Only in second: " + onlySecond.joined(separator: ", "),
            ].compactMap { $0 }.joined(separator: " | ")
            return LocalToolOutput(
                name: call.name,
                status: .ok,
                evidenceIDs: [issuedFirst.evidenceID, issuedSecond.evidenceID],
                packReleaseID: database.packIdentity.sourceCommitSHA,
                sourceSHA: database.packIdentity.sourceCommitSHA,
                payload: .message(summary),
                notice: first.derivedEvidence.provenanceLabel
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return rejected(name: call.name, message: error.localizedDescription)
        }
    }

    private func rejected(name: String, message: String) -> LocalToolOutput {
        LocalToolOutput(
            name: name,
            status: .rejected,
            evidenceIDs: [],
            packReleaseID: database.packIdentity.sourceCommitSHA,
            sourceSHA: database.packIdentity.sourceCommitSHA,
            payload: .message(message),
            notice: message
        )
    }
}
