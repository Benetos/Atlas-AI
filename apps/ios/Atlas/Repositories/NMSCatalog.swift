import Foundation

enum CatalogRecordID: Hashable, Sendable, Equatable {
    case entity(type: String, id: String)
    case recipe(id: String)
    case content(dataset: String, id: String, sourceOrdinal: Int)
}

enum CatalogError: Error, Equatable, LocalizedError, Sendable {
    case notFound(CatalogRecordID)
    case unsupported(String)
    case unavailable
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "The record is not in this snapshot."
        case .unsupported(let message):
            return message
        case .unavailable:
            return "The local Atlas pack is unavailable."
        case .failure(let message):
            return message
        }
    }
}

protocol NMSCatalog: Sendable {
    func packIdentity() async throws -> PackIdentity
    func entity(type: String, id: String) async throws -> Entity
    func recipe(id: String) async throws -> Recipe
    func content(dataset: String, id: String, sourceOrdinal: Int) async throws -> ContentRecord
    func recipesProducing(type: String, id: String) async throws -> [Recipe]
    func recipesUsing(type: String, id: String) async throws -> [Recipe]
    func searchEntities(query: String, type: String?, limit: Int) async throws -> [Entity]
    func searchRecipes(query: String, kind: String?, limit: Int) async throws -> [Recipe]
    func searchContent(query: String, dataset: String?, limit: Int) async throws -> [ContentRecord]
    func entities(type: String, limit: Int, offset: Int) async throws -> [Entity]
    func recipes(kind: String?, limit: Int, offset: Int) async throws -> [Recipe]
    func contentRecords(dataset: String, limit: Int, offset: Int) async throws -> [ContentRecord]
}

struct SQLiteNMSCatalog: NMSCatalog {
    let store: any NMSStore
    let packRole: String?

    func packIdentity() async throws -> PackIdentity {
        let role = packRole
        return try await run { store in
            PackIdentity(manifest: try store.manifest(), packRole: role)
        }
    }

    func entity(type: String, id: String) async throws -> Entity {
        try await run { store in
            guard let entity = try store.entity(type: type, id: id) else {
                throw CatalogError.notFound(.entity(type: type, id: id))
            }
            return entity
        }
    }

    func recipe(id: String) async throws -> Recipe {
        try await run { store in
            guard let recipe = try store.recipe(id: id) else {
                throw CatalogError.notFound(.recipe(id: id))
            }
            return recipe
        }
    }

    func content(dataset: String, id: String, sourceOrdinal: Int) async throws -> ContentRecord {
        try await run { store in
            guard let record = try store.content(
                dataset: dataset,
                id: id,
                sourceOrdinal: sourceOrdinal
            ) else {
                throw CatalogError.notFound(
                    .content(dataset: dataset, id: id, sourceOrdinal: sourceOrdinal)
                )
            }
            return record
        }
    }

    func recipesProducing(type: String, id: String) async throws -> [Recipe] {
        try await run { store in try store.recipesProducing(type: type, id: id) }
    }

    func recipesUsing(type: String, id: String) async throws -> [Recipe] {
        try await run { store in try store.recipesUsing(type: type, id: id) }
    }

    func searchEntities(query: String, type: String?, limit: Int) async throws -> [Entity] {
        try await run { store in try store.searchEntities(query: query, type: type, limit: limit) }
    }

    func searchRecipes(query: String, kind: String?, limit: Int) async throws -> [Recipe] {
        try await run { store in try store.searchRecipes(query: query, kind: kind, limit: limit) }
    }

    func searchContent(query: String, dataset: String?, limit: Int) async throws -> [ContentRecord] {
        try await run { store in try store.searchContent(query: query, dataset: dataset, limit: limit) }
    }

    func entities(type: String, limit: Int, offset: Int) async throws -> [Entity] {
        try await run { store in try store.entities(type: type, limit: limit, offset: offset) }
    }

    func recipes(kind: String?, limit: Int, offset: Int) async throws -> [Recipe] {
        try await run { store in try store.recipes(kind: kind, limit: limit, offset: offset) }
    }

    func contentRecords(dataset: String, limit: Int, offset: Int) async throws -> [ContentRecord] {
        try await run { store in try store.contentRecords(dataset: dataset, limit: limit, offset: offset) }
    }

    private func run<T: Sendable>(
        _ work: @escaping @Sendable (any NMSStore) throws -> T
    ) async throws -> T {
        let store = self.store
        do {
            return try await Task.detached(priority: .userInitiated) {
                try work(store)
            }.value
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.failure(error.localizedDescription)
        }
    }
}

struct FixtureNMSCatalog: NMSCatalog {
    var identity: PackIdentity
    var entities: [Entity]
    var recipes: [Recipe]
    var records: [ContentRecord]
    var forcedError: CatalogError?

    func packIdentity() async throws -> PackIdentity {
        try throwIfForced()
        return identity
    }

    func entity(type: String, id: String) async throws -> Entity {
        try throwIfForced()
        guard let entity = entities.first(where: { $0.entityType == type && $0.gameID == id }) else {
            throw CatalogError.notFound(.entity(type: type, id: id))
        }
        return entity
    }

    func recipe(id: String) async throws -> Recipe {
        try throwIfForced()
        guard let recipe = recipes.first(where: { $0.recipeID == id }) else {
            throw CatalogError.notFound(.recipe(id: id))
        }
        return recipe
    }

    func content(dataset: String, id: String, sourceOrdinal: Int) async throws -> ContentRecord {
        try throwIfForced()
        guard let record = records.first(where: {
            $0.dataset == dataset && $0.externalID == id && $0.sourceOrdinal == sourceOrdinal
        }) else {
            throw CatalogError.notFound(
                .content(dataset: dataset, id: id, sourceOrdinal: sourceOrdinal)
            )
        }
        return record
    }

    func recipesProducing(type: String, id: String) async throws -> [Recipe] {
        try throwIfForced()
        return recipes.filter { $0.outputEntityType == type && $0.outputGameID == id }
    }

    func recipesUsing(type: String, id: String) async throws -> [Recipe] {
        try throwIfForced()
        return recipes.filter { recipe in
            recipe.ingredients.contains { $0.entityType == type && $0.gameID == id }
        }
    }

    func searchEntities(query: String, type: String?, limit: Int) async throws -> [Entity] {
        try throwIfForced()
        let needle = query.lowercased()
        return Array(
            entities.filter { entity in
                (type == nil || entity.entityType == type)
                    && entity.title.lowercased().contains(needle)
            }.prefix(limit)
        )
    }

    func searchRecipes(query: String, kind: String?, limit: Int) async throws -> [Recipe] {
        try throwIfForced()
        let needle = query.lowercased()
        return Array(
            recipes.filter { recipe in
                (kind == nil || recipe.recipeKind == kind)
                    && recipe.title.lowercased().contains(needle)
            }.prefix(limit)
        )
    }

    func searchContent(query: String, dataset: String?, limit: Int) async throws -> [ContentRecord] {
        try throwIfForced()
        let needle = query.lowercased()
        return Array(
            records.filter { record in
                (dataset == nil || record.dataset == dataset)
                    && record.title.lowercased().contains(needle)
            }.prefix(limit)
        )
    }

    func entities(type: String, limit: Int, offset: Int) async throws -> [Entity] {
        try throwIfForced()
        return Array(entities.filter { $0.entityType == type }.dropFirst(offset).prefix(limit))
    }

    func recipes(kind: String?, limit: Int, offset: Int) async throws -> [Recipe] {
        try throwIfForced()
        let filtered = recipes.filter { kind == nil || $0.recipeKind == kind }
        return Array(filtered.dropFirst(offset).prefix(limit))
    }

    func contentRecords(dataset: String, limit: Int, offset: Int) async throws -> [ContentRecord] {
        try throwIfForced()
        return Array(records.filter { $0.dataset == dataset }.dropFirst(offset).prefix(limit))
    }

    private func throwIfForced() throws {
        if let forcedError {
            throw forcedError
        }
    }
}
