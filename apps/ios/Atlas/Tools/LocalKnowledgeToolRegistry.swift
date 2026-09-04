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

    init(database: LocalDatabaseToolRegistry, calculationToolNames: [String] = ["scale_quantity", "plan_recipe"]) {
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
