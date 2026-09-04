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

    init(database: LocalDatabaseToolRegistry, calculationToolNames: [String] = ["scale_quantity"]) {
        self.database = database
        self.calculationToolNames = calculationToolNames
    }

    func beginTurn() {
        database.beginTurn()
    }

    func invoke(_ call: LocalToolCall) async throws -> LocalToolOutput {
        if calculationToolNames.contains(call.name) {
            return scaleQuantity(call)
        }
        return try await database.invoke(call)
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
}
