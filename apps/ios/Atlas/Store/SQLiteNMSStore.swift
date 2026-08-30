import Foundation
import SQLite3

enum NMSStoreError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .queryFailed(let message):
            return message
        }
    }
}

protocol NMSStore: Sendable {
    func manifest() throws -> PackManifest
    func entity(type: String, id: String) throws -> Entity?
    func searchEntities(query: String, type: String?, limit: Int) throws -> [Entity]
    func entities(type: String, limit: Int, offset: Int) throws -> [Entity]
    func recipes(kind: String?, limit: Int, offset: Int) throws -> [Recipe]
    func recipe(id: String) throws -> Recipe?
    func recipesProducing(type: String, id: String) throws -> [Recipe]
    func recipesUsing(type: String, id: String) throws -> [Recipe]
    func searchContent(query: String, dataset: String?, limit: Int) throws -> [ContentRecord]
}

final class SQLiteNMSStore: NMSStore, @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    init(fileURL: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(fileURL.path, &db, flags, nil)
        if status != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NMSStoreError.openFailed("Could not open Atlas pack: \(message)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func manifest() throws -> PackManifest {
        try withLock {
            let sql = """
            select pack_schema_version, contract_version, source_repository,
                   source_commit_sha, source_committed_at, generated_at, counts_json
              from pack_manifest
             limit 1
            """
            return try query(sql, parameters: []) { stmt in
                PackManifest(
                    packSchemaVersion: Int(sqlite3_column_int(stmt, 0)),
                    contractVersion: Int(sqlite3_column_int(stmt, 1)),
                    sourceRepository: Self.text(stmt, 2) ?? "",
                    sourceCommitSHA: Self.text(stmt, 3) ?? "",
                    sourceCommittedAt: Self.text(stmt, 4),
                    generatedAt: Self.text(stmt, 5) ?? "",
                    countsJSON: Self.text(stmt, 6) ?? "{}"
                )
            }.first ?? PackManifest(
                packSchemaVersion: 1,
                contractVersion: 1,
                sourceRepository: "",
                sourceCommitSHA: "",
                sourceCommittedAt: nil,
                generatedAt: "",
                countsJSON: "{}"
            )
        }
    }

    func entity(type: String, id: String) throws -> Entity? {
        try withLock {
            try query(
                """
                select entity_type, game_id, name, display_name, subtitle, description,
                       category, subcategory, rarity, legality, base_value,
                       color_r, color_g, color_b, source_dataset, source_commit_sha
                  from nms_entities
                 where entity_type = ? and game_id = ?
                """,
                parameters: [.text(type), .text(id)],
                map: Self.mapEntity
            ).first
        }
    }

    func searchEntities(query: String, type: String?, limit: Int = 20) throws -> [Entity] {
        let match = Self.ftsQuery(query)
        return try withLock {
            var sql = """
            select e.entity_type, e.game_id, e.name, e.display_name, e.subtitle, e.description,
                   e.category, e.subcategory, e.rarity, e.legality, e.base_value,
                   e.color_r, e.color_g, e.color_b, e.source_dataset, e.source_commit_sha
              from nms_entities_fts
              join nms_entities e
                on e.entity_type = nms_entities_fts.entity_type
               and e.game_id = nms_entities_fts.game_id
             where nms_entities_fts match ?
            """
            var parameters: [SQLValue] = [.text(match)]
            if let type {
                sql += " and e.entity_type = ?"
                parameters.append(.text(type))
            }
            sql += " order by bm25(nms_entities_fts, 10.0, 10.0, 3.0, 1.0) limit ?"
            parameters.append(.int(limit))
            return try query(sql, parameters: parameters, map: Self.mapEntity)
        }
    }

    func entities(type: String, limit: Int = 100, offset: Int = 0) throws -> [Entity] {
        try withLock {
            try query(
                """
                select entity_type, game_id, name, display_name, subtitle, description,
                       category, subcategory, rarity, legality, base_value,
                       color_r, color_g, color_b, source_dataset, source_commit_sha
                  from nms_entities
                 where entity_type = ?
                 order by lower(coalesce(display_name, name, game_id))
                 limit ? offset ?
                """,
                parameters: [.text(type), .int(limit), .int(offset)],
                map: Self.mapEntity
            )
        }
    }

    func recipes(kind: String?, limit: Int = 100, offset: Int = 0) throws -> [Recipe] {
        try withLock {
            var sql = """
            select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                   r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                   r.source_ordinal, r.source_commit_sha,
                   coalesce(e.display_name, e.name, r.output_game_id)
              from nms_recipes r
              left join nms_entities e
                on e.entity_type = r.output_entity_type
               and e.game_id = r.output_game_id
            """
            var parameters: [SQLValue] = []
            if let kind {
                sql += " where r.recipe_kind = ?"
                parameters.append(.text(kind))
            }
            sql += " order by lower(coalesce(r.recipe_name, e.display_name, r.recipe_id)) limit ? offset ?"
            parameters.append(.int(limit))
            parameters.append(.int(offset))
            return try query(sql, parameters: parameters, map: Self.mapRecipe).map { recipe in
                var copy = recipe
                copy.ingredients = (try? self.ingredientsUnlocked(recipeID: recipe.recipeID)) ?? []
                return copy
            }
        }
    }

    func recipe(id: String) throws -> Recipe? {
        try withLock {
            guard var recipe = try query(
                """
                select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                       r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                       r.source_ordinal, r.source_commit_sha,
                       coalesce(e.display_name, e.name, r.output_game_id)
                  from nms_recipes r
                  left join nms_entities e
                    on e.entity_type = r.output_entity_type
                   and e.game_id = r.output_game_id
                 where r.recipe_id = ?
                """,
                parameters: [.text(id)],
                map: Self.mapRecipe
            ).first else { return nil }
            recipe.ingredients = try ingredientsUnlocked(recipeID: id)
            return recipe
        }
    }

    func recipesProducing(type: String, id: String) throws -> [Recipe] {
        try withLock {
            try query(
                """
                select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                       r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                       r.source_ordinal, r.source_commit_sha,
                       coalesce(e.display_name, e.name, r.output_game_id)
                  from nms_recipes r
                  left join nms_entities e
                    on e.entity_type = r.output_entity_type
                   and e.game_id = r.output_game_id
                 where r.output_entity_type = ? and r.output_game_id = ?
                 order by r.recipe_kind, r.recipe_id
                """,
                parameters: [.text(type), .text(id)],
                map: Self.mapRecipe
            ).map { recipe in
                var copy = recipe
                copy.ingredients = (try? self.ingredientsUnlocked(recipeID: recipe.recipeID)) ?? []
                return copy
            }
        }
    }

    func recipesUsing(type: String, id: String) throws -> [Recipe] {
        try withLock {
            try query(
                """
                select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                       r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                       r.source_ordinal, r.source_commit_sha,
                       coalesce(e.display_name, e.name, r.output_game_id)
                  from nms_recipe_ingredients i
                  join nms_recipes r on r.recipe_id = i.recipe_id
                  left join nms_entities e
                    on e.entity_type = r.output_entity_type
                   and e.game_id = r.output_game_id
                 where i.ingredient_entity_type = ? and i.ingredient_game_id = ?
                 order by r.recipe_kind, r.recipe_id
                """,
                parameters: [.text(type), .text(id)],
                map: Self.mapRecipe
            ).map { recipe in
                var copy = recipe
                copy.ingredients = (try? self.ingredientsUnlocked(recipeID: recipe.recipeID)) ?? []
                return copy
            }
        }
    }

    func searchContent(query: String, dataset: String?, limit: Int = 20) throws -> [ContentRecord] {
        let match = Self.ftsQuery(query)
        return try withLock {
            var sql = """
            select c.dataset, c.external_id, c.source_ordinal, c.display_name,
                   c.payload, c.source_commit_sha
              from nms_content_fts
              join nms_content_records c
                on c.dataset = nms_content_fts.dataset
               and c.external_id = nms_content_fts.external_id
               and c.source_ordinal = nms_content_fts.source_ordinal
             where nms_content_fts match ?
            """
            var parameters: [SQLValue] = [.text(match)]
            if let dataset {
                sql += " and c.dataset = ?"
                parameters.append(.text(dataset))
            }
            sql += " order by bm25(nms_content_fts, 5.0, 1.0) limit ?"
            parameters.append(.int(limit))
            return try query(sql, parameters: parameters) { stmt in
                ContentRecord(
                    dataset: Self.text(stmt, 0) ?? "",
                    externalID: Self.text(stmt, 1) ?? "",
                    sourceOrdinal: Int(sqlite3_column_int(stmt, 2)),
                    displayName: Self.text(stmt, 3),
                    payload: Self.text(stmt, 4) ?? "{}",
                    sourceCommitSHA: Self.text(stmt, 5) ?? ""
                )
            }
        }
    }

    private func ingredientsUnlocked(recipeID: String) throws -> [RecipeIngredient] {
        try query(
            """
            select i.recipe_id, i.position, i.ingredient_entity_type, i.ingredient_game_id,
                   i.amount, coalesce(e.display_name, e.name, i.ingredient_game_id)
              from nms_recipe_ingredients i
              left join nms_entities e
                on e.entity_type = i.ingredient_entity_type
               and e.game_id = i.ingredient_game_id
             where i.recipe_id = ?
             order by i.position
            """,
            parameters: [.text(recipeID)]
        ) { stmt in
            RecipeIngredient(
                recipeID: Self.text(stmt, 0) ?? recipeID,
                position: Int(sqlite3_column_int(stmt, 1)),
                entityType: Self.text(stmt, 2) ?? "",
                gameID: Self.text(stmt, 3) ?? "",
                amount: Self.text(stmt, 4),
                title: Self.text(stmt, 5)
            )
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private enum SQLValue {
        case text(String)
        case int(Int)
    }

    private func query<T>(
        _ sql: String,
        parameters: [SQLValue],
        map: (OpaquePointer) -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NMSStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (index, parameter) in parameters.enumerated() {
            let slot = Int32(index + 1)
            switch parameter {
            case .text(let value):
                sqlite3_bind_text(stmt, slot, value, -1, SQLITE_TRANSIENT)
            case .int(let value):
                sqlite3_bind_int(stmt, slot, Int32(value))
            }
        }
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(map(stmt))
        }
        return rows
    }

    private static func mapEntity(_ stmt: OpaquePointer) -> Entity {
        Entity(
            entityType: text(stmt, 0) ?? "",
            gameID: text(stmt, 1) ?? "",
            name: text(stmt, 2),
            displayName: text(stmt, 3),
            subtitle: text(stmt, 4),
            description: text(stmt, 5),
            category: text(stmt, 6),
            subcategory: text(stmt, 7),
            rarity: text(stmt, 8),
            legality: text(stmt, 9),
            baseValue: text(stmt, 10),
            colorR: text(stmt, 11),
            colorG: text(stmt, 12),
            colorB: text(stmt, 13),
            sourceDataset: text(stmt, 14) ?? "",
            sourceCommitSHA: text(stmt, 15) ?? ""
        )
    }

    private static func mapRecipe(_ stmt: OpaquePointer) -> Recipe {
        Recipe(
            recipeID: text(stmt, 0) ?? "",
            recipeKind: text(stmt, 1) ?? "",
            outputEntityType: text(stmt, 2) ?? "",
            outputGameID: text(stmt, 3) ?? "",
            outputAmount: text(stmt, 4),
            timeSeconds: text(stmt, 5),
            recipeType: text(stmt, 6),
            recipeName: text(stmt, 7),
            sourceOrdinal: Int(sqlite3_column_int(stmt, 8)),
            sourceCommitSHA: text(stmt, 9) ?? "",
            ingredients: [],
            outputTitle: text(stmt, 10)
        )
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(stmt, index) else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    static func ftsQuery(_ raw: String) -> String {
        let tokens = raw.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        if tokens.isEmpty { return "\"\"" }
        return tokens.map { "\"\($0)\"" }.joined(separator: " AND ")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
