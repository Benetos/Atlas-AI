import Foundation

enum LocalToolName: String, CaseIterable, Sendable {
    case searchEntities = "search_entities"
    case getEntity = "get_entity"
    case searchRecipes = "search_recipes"
    case getRecipe = "get_recipe"
    case recipesFor = "recipes_for"
    case recipesUsing = "recipes_using"
    case searchContent = "search_content"
    case getContent = "get_content"
    case getPackProvenance = "get_pack_provenance"

    static var coreNames: [String] { allCases.map(\.rawValue) }

    var isDomainTool: Bool { false }
}

enum LocalToolStatus: String, Equatable, Sendable {
    case ok
    case notFound
    case rejected
    case failed
}

enum LocalToolPayload: Equatable, Sendable {
    case entities([Entity])
    case entity(Entity)
    case recipes([Recipe])
    case recipe(Recipe)
    case content([ContentRecord])
    case record(ContentRecord)
    case provenance(PackIdentity)
    case empty
    case message(String)
}

struct LocalToolCall: Equatable, Sendable {
    var name: String
    var query: String? = nil
    var entityType: String? = nil
    var gameID: String? = nil
    var recipeID: String? = nil
    var recipeKind: String? = nil
    var dataset: String? = nil
    var sourceOrdinal: Int? = nil
    var limit: Int? = nil
    var quantity: Int? = nil
}

struct LocalToolOutput: Equatable, Sendable {
    var name: String
    var status: LocalToolStatus
    var evidenceIDs: [String]
    var packReleaseID: String
    var sourceSHA: String
    var payload: LocalToolPayload
    var notice: String?
}

/// Concrete, fixed, SQLite/catalog-only, read-only database tools.
///
/// Outputs are typed and carry status, evidence IDs, pack release, and source SHA.
/// This type must not grow network, saved-store, router, or executor dependencies.
final class LocalDatabaseToolRegistry: @unchecked Sendable {
    static let expectedNames = LocalToolName.coreNames

    let catalog: any NMSCatalog
    let ledger: EvidenceLedger
    let packIdentity: PackIdentity

    private let lock = NSLock()
    private var toolCallsThisTurn = 0
    private var domainToolsThisTurn: Set<String> = []

    init(catalog: any NMSCatalog, ledger: EvidenceLedger, packIdentity: PackIdentity) {
        self.catalog = catalog
        self.ledger = ledger
        self.packIdentity = packIdentity
    }

    func beginTurn() {
        lock.lock()
        toolCallsThisTurn = 0
        domainToolsThisTurn.removeAll()
        lock.unlock()
    }

    func invoke(_ call: LocalToolCall) async throws -> LocalToolOutput {
        if let rejection = register(call) {
            return rejection
        }
        do {
            return try await execute(call)
        } catch let error as CatalogError {
            if case .notFound = error {
                return output(name: call.name, status: .notFound, payload: .empty, notice: error.localizedDescription)
            }
            return output(
                name: call.name,
                status: .failed,
                payload: .message(error.localizedDescription),
                notice: error.localizedDescription
            )
        } catch let error as ConversationBoundError {
            return output(
                name: call.name,
                status: .rejected,
                payload: .message(error.localizedDescription ?? "Rejected"),
                notice: error.localizedDescription
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return output(
                name: call.name,
                status: .failed,
                payload: .message(error.localizedDescription),
                notice: error.localizedDescription
            )
        }
    }

    private func register(_ call: LocalToolCall) -> LocalToolOutput? {
        lock.lock()
        defer { lock.unlock() }
        toolCallsThisTurn += 1
        if toolCallsThisTurn > ConversationBounds.maxToolCallsPerTurn {
            return output(
                name: call.name,
                status: .rejected,
                payload: .message("Too many tool calls"),
                notice: ConversationBoundError.tooManyToolCalls(toolCallsThisTurn).localizedDescription
            )
        }
        if LocalToolName(rawValue: call.name) == nil {
            domainToolsThisTurn.insert(call.name)
            if domainToolsThisTurn.count > ConversationBounds.maxDomainToolsPerTurn {
                return output(
                    name: call.name,
                    status: .rejected,
                    payload: .message("Too many domain tools"),
                    notice: ConversationBoundError.tooManyDomainTools(domainToolsThisTurn.count).localizedDescription
                )
            }
            return output(
                name: call.name,
                status: .rejected,
                payload: .message("Unknown tool"),
                notice: "Unknown tool \(call.name)"
            )
        }
        return nil
    }

    private func execute(_ call: LocalToolCall) async throws -> LocalToolOutput {
        guard let name = LocalToolName(rawValue: call.name) else {
            return output(name: call.name, status: .rejected, payload: .message("Unknown tool"))
        }
        switch name {
        case .searchEntities:
            let query = try ConversationBounds.normalizeQuery(call.query ?? "")
            let limit = try ConversationBounds.clampSearchLimit(call.limit)
            let rows = try await catalog.searchEntities(query: query, type: call.entityType, limit: limit)
            let issued = rows.map { ledger.issue(payload: .entity($0), source: .packed) }
            return output(name: call.name, status: .ok, evidenceIDs: issued.map(\.evidenceID), payload: .entities(rows))

        case .getEntity:
            guard let type = call.entityType, let id = call.gameID else {
                return output(name: call.name, status: .rejected, payload: .message("Missing entity identity"))
            }
            let entity = try await catalog.entity(type: type, id: id)
            let issued = ledger.issue(payload: .entity(entity), source: .packed)
            return output(name: call.name, status: .ok, evidenceIDs: [issued.evidenceID], payload: .entity(entity))

        case .searchRecipes:
            let query = try ConversationBounds.normalizeQuery(call.query ?? "")
            let limit = try ConversationBounds.clampSearchLimit(call.limit)
            let rows = try await catalog.searchRecipes(query: query, kind: call.recipeKind, limit: limit)
            let issued = rows.map { ledger.issue(payload: .recipe($0), source: .packed) }
            return output(name: call.name, status: .ok, evidenceIDs: issued.map(\.evidenceID), payload: .recipes(rows))

        case .getRecipe:
            guard let id = call.recipeID else {
                return output(name: call.name, status: .rejected, payload: .message("Missing recipe identity"))
            }
            let recipe = try await catalog.recipe(id: id)
            let issued = ledger.issue(payload: .recipe(recipe), source: .packed)
            return output(name: call.name, status: .ok, evidenceIDs: [issued.evidenceID], payload: .recipe(recipe))

        case .recipesFor:
            guard let type = call.entityType, let id = call.gameID else {
                return output(name: call.name, status: .rejected, payload: .message("Missing entity identity"))
            }
            let limit = try ConversationBounds.clampSearchLimit(call.limit)
            let rows = Array(try await catalog.recipesProducing(type: type, id: id).prefix(limit))
            let issued = rows.map { ledger.issue(payload: .recipe($0), source: .packed) }
            return output(name: call.name, status: .ok, evidenceIDs: issued.map(\.evidenceID), payload: .recipes(rows))

        case .recipesUsing:
            guard let type = call.entityType, let id = call.gameID else {
                return output(name: call.name, status: .rejected, payload: .message("Missing entity identity"))
            }
            let limit = try ConversationBounds.clampSearchLimit(call.limit)
            let rows = Array(try await catalog.recipesUsing(type: type, id: id).prefix(limit))
            let issued = rows.map { ledger.issue(payload: .recipe($0), source: .packed) }
            return output(name: call.name, status: .ok, evidenceIDs: issued.map(\.evidenceID), payload: .recipes(rows))

        case .searchContent:
            let query = try ConversationBounds.normalizeQuery(call.query ?? "")
            let limit = try ConversationBounds.clampSearchLimit(call.limit)
            let rows = try await catalog.searchContent(query: query, dataset: call.dataset, limit: limit)
            let issued = rows.map { ledger.issue(payload: .content($0), source: .packed) }
            return output(name: call.name, status: .ok, evidenceIDs: issued.map(\.evidenceID), payload: .content(rows))

        case .getContent:
            guard let dataset = call.dataset, let id = call.gameID, let ordinal = call.sourceOrdinal else {
                return output(name: call.name, status: .rejected, payload: .message("Missing content identity"))
            }
            let record = try await catalog.content(dataset: dataset, id: id, sourceOrdinal: ordinal)
            try ConversationBounds.rejectOversizedDetail(record.payload)
            let issued = ledger.issue(payload: .content(record), source: .packed)
            return output(name: call.name, status: .ok, evidenceIDs: [issued.evidenceID], payload: .record(record))

        case .getPackProvenance:
            let identity = try await catalog.packIdentity()
            return output(
                name: call.name,
                status: .ok,
                payload: .provenance(identity)
            )
        }
    }

    private func output(
        name: String,
        status: LocalToolStatus,
        evidenceIDs: [String] = [],
        payload: LocalToolPayload,
        notice: String? = nil
    ) -> LocalToolOutput {
        LocalToolOutput(
            name: name,
            status: status,
            evidenceIDs: evidenceIDs,
            packReleaseID: packIdentity.sourceCommitSHA,
            sourceSHA: packIdentity.sourceCommitSHA,
            payload: payload,
            notice: notice
        )
    }
}
