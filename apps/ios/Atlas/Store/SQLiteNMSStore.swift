import Foundation
import SQLite3

private func atlasSQLiteAuthorizer(
    _: UnsafeMutableRawPointer?,
    action: Int32,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?
) -> Int32 {
    switch action {
    case SQLITE_ATTACH, SQLITE_DETACH,
         SQLITE_INSERT, SQLITE_DELETE, SQLITE_UPDATE,
         SQLITE_CREATE_INDEX, SQLITE_CREATE_TABLE, SQLITE_CREATE_TEMP_INDEX,
         SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_TEMP_TRIGGER, SQLITE_CREATE_TEMP_VIEW,
         SQLITE_CREATE_TRIGGER, SQLITE_CREATE_VIEW,
         SQLITE_DROP_INDEX, SQLITE_DROP_TABLE, SQLITE_DROP_TEMP_INDEX,
         SQLITE_DROP_TEMP_TABLE, SQLITE_DROP_TEMP_TRIGGER, SQLITE_DROP_TEMP_VIEW,
         SQLITE_DROP_TRIGGER, SQLITE_DROP_VIEW,
         SQLITE_ALTER_TABLE, SQLITE_REINDEX,
         SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
        return SQLITE_DENY
    default:
        return SQLITE_OK
    }
}

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
    func searchRecipes(query: String, kind: String?, limit: Int) throws -> [Recipe]
    func recipe(id: String) throws -> Recipe?
    func recipesProducing(type: String, id: String) throws -> [Recipe]
    func recipesUsing(type: String, id: String) throws -> [Recipe]
    func content(dataset: String, id: String, sourceOrdinal: Int) throws -> ContentRecord?
    func searchContent(query: String, dataset: String?, limit: Int) throws -> [ContentRecord]
}

final class SQLiteNMSStore: NMSStore, @unchecked Sendable {
    private struct StoredManifest {
        var value: PackManifest
        var inputManifestSHA256: String
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    init(fileURL: URL) throws {
        guard fileURL.isFileURL else {
            throw NMSStoreError.openFailed("Atlas packs must be local files.")
        }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(fileURL.path, &db, flags, nil)
        if status != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            throw NMSStoreError.openFailed("Could not open Atlas pack: \(message)")
        }
        guard sqlite3_set_authorizer(db, atlasSQLiteAuthorizer, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            throw NMSStoreError.openFailed("Could not secure Atlas pack: \(message)")
        }
        guard sqlite3_exec(db, "pragma query_only = on", nil, nil, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            throw NMSStoreError.openFailed("Could not make Atlas pack query-only: \(message)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func validateIntegrity() throws {
        try withLock {
            let quick: [String] = try query("pragma quick_check", parameters: []) { stmt in
                Self.text(stmt, 0) ?? ""
            }
            guard quick == ["ok"] else {
                throw NMSStoreError.queryFailed(
                    "Atlas pack quick_check failed: \(quick.joined(separator: ", "))"
                )
            }
            let foreignKeys: [String] = try query(
                "pragma foreign_key_check",
                parameters: []
            ) { stmt in
                Self.text(stmt, 0) ?? "foreign key error"
            }
            guard foreignKeys.isEmpty else {
                throw NMSStoreError.queryFailed("Atlas pack contains invalid relationships.")
            }
        }
    }

    func databaseCounts() throws -> [String: Int] {
        try withLock {
            try databaseCountsUnlocked()
        }
    }

    /// Exercises the two operations that would let a future dynamic query
    /// escape the immutable pack boundary. Both must be denied by the SQLite
    /// authorizer in addition to the read-only open flags.
    func validateReadOnlyBoundary() throws {
        try withLock {
            guard sqlite3_exec(
                db,
                "create table atlas_write_probe(value text)",
                nil,
                nil,
                nil
            ) != SQLITE_OK else {
                throw NMSStoreError.queryFailed("Atlas pack unexpectedly allowed a write.")
            }
            guard sqlite3_exec(
                db,
                "attach database ':memory:' as atlas_attach_probe",
                nil,
                nil,
                nil
            ) != SQLITE_OK else {
                sqlite3_exec(db, "detach database atlas_attach_probe", nil, nil, nil)
                throw NMSStoreError.queryFailed("Atlas pack unexpectedly allowed ATTACH.")
            }
        }
    }

    func manifest() throws -> PackManifest {
        try withLock {
            let sql = """
            select pack_schema_version, contract_version, source_repository,
                   source_commit_sha, source_committed_at, generated_at, counts_json,
                   input_manifest_sha256
              from pack_manifest
             limit 2
            """
            let manifests: [StoredManifest] = try query(sql, parameters: []) { stmt in
                StoredManifest(
                    value: PackManifest(
                        packSchemaVersion: Int(sqlite3_column_int(stmt, 0)),
                        contractVersion: Int(sqlite3_column_int(stmt, 1)),
                        sourceRepository: Self.text(stmt, 2) ?? "",
                        sourceCommitSHA: Self.text(stmt, 3) ?? "",
                        sourceCommittedAt: Self.text(stmt, 4),
                        generatedAt: Self.text(stmt, 5) ?? "",
                        countsJSON: Self.text(stmt, 6) ?? ""
                    ),
                    inputManifestSHA256: Self.text(stmt, 7) ?? ""
                )
            }
            guard manifests.count == 1, let stored = manifests.first else {
                throw NMSStoreError.queryFailed(
                    "The Atlas pack must contain exactly one manifest row; found \(manifests.count)."
                )
            }
            let manifest = stored.value
            guard manifest.packSchemaVersion == 1 else {
                throw NMSStoreError.queryFailed(
                    "This Atlas pack uses unsupported schema version \(manifest.packSchemaVersion)."
                )
            }
            guard manifest.contractVersion == 1 else {
                throw NMSStoreError.queryFailed(
                    "This Atlas pack uses unsupported contract version \(manifest.contractVersion)."
                )
            }
            guard Self.isPlausibleRepository(manifest.sourceRepository) else {
                throw NMSStoreError.queryFailed("The Atlas pack has invalid source repository metadata.")
            }
            guard Self.isLowercaseHex(manifest.sourceCommitSHA, length: 40) else {
                throw NMSStoreError.queryFailed("The Atlas pack has an invalid source commit SHA.")
            }
            guard Self.isLowercaseHex(stored.inputManifestSHA256, length: 64) else {
                throw NMSStoreError.queryFailed("The Atlas pack has an invalid input manifest SHA-256.")
            }
            guard Self.isISO8601(manifest.generatedAt) else {
                throw NMSStoreError.queryFailed("The Atlas pack has an invalid generation timestamp.")
            }
            if let sourceCommittedAt = manifest.sourceCommittedAt,
               !Self.isISO8601(sourceCommittedAt) {
                throw NMSStoreError.queryFailed("The Atlas pack has an invalid source commit timestamp.")
            }

            let expectedCounts = try Self.decodeCounts(manifest.countsJSON)
            let actualCounts = try databaseCountsUnlocked()
            guard expectedCounts == actualCounts else {
                throw NMSStoreError.queryFailed(
                    "The Atlas pack manifest counts do not match its database rows."
                )
            }
            try validateFTSUnlocked(expectedCounts: expectedCounts)
            try validateRowProvenanceUnlocked(sourceCommitSHA: manifest.sourceCommitSHA)
            return manifest
        }
    }

    private func databaseCountsUnlocked() throws -> [String: Int] {
        let tables = [
            "entities": "nms_entities",
            "localizations_preferred": "nms_localizations",
            "recipes": "nms_recipes",
            "recipe_ingredients": "nms_recipe_ingredients",
            "content_records": "nms_content_records",
        ]
        var counts: [String: Int] = [:]
        for (key, table) in tables {
            let rows: [Int] = try query(
                "select count(*) from \(table)",
                parameters: []
            ) { stmt in
                Int(sqlite3_column_int64(stmt, 0))
            }
            guard let count = rows.first else {
                throw NMSStoreError.queryFailed("Could not count \(table).")
            }
            counts[key] = count
        }
        return counts
    }

    private func validateFTSUnlocked(expectedCounts: [String: Int]) throws {
        let requirements = [
            (table: "nms_entities_fts", countKey: "entities"),
            (table: "nms_content_fts", countKey: "content_records"),
        ]
        for requirement in requirements {
            let definitions: [String] = try query(
                "select sql from sqlite_schema where type = 'table' and name = ?",
                parameters: [.text(requirement.table)]
            ) { stmt in
                Self.text(stmt, 0) ?? ""
            }
            guard definitions.count == 1,
                  definitions[0].lowercased().contains("using fts5") else {
                throw NMSStoreError.queryFailed(
                    "The Atlas pack is missing required FTS5 table \(requirement.table)."
                )
            }
            let rows: [Int] = try query(
                "select count(*) from \(requirement.table)",
                parameters: []
            ) { stmt in
                Int(sqlite3_column_int64(stmt, 0))
            }
            guard let actual = rows.first,
                  let expected = expectedCounts[requirement.countKey],
                  actual == expected else {
                throw NMSStoreError.queryFailed(
                    "The Atlas pack FTS row count does not match \(requirement.countKey)."
                )
            }
        }
    }

    private func validateRowProvenanceUnlocked(sourceCommitSHA: String) throws {
        let tables = [
            "nms_entities",
            "nms_localizations",
            "nms_recipes",
            "nms_recipe_ingredients",
            "nms_content_records",
        ]
        for table in tables {
            let mismatches: [Int] = try query(
                "select count(*) from \(table) where source_commit_sha is null or source_commit_sha <> ?",
                parameters: [.text(sourceCommitSHA)]
            ) { stmt in
                Int(sqlite3_column_int64(stmt, 0))
            }
            guard mismatches.first == 0 else {
                throw NMSStoreError.queryFailed(
                    "The Atlas pack contains rows from a different source commit."
                )
            }
        }
    }

    private static func decodeCounts(_ json: String) throws -> [String: Int] {
        guard let data = json.data(using: .utf8),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data),
              counts.values.allSatisfy({ $0 >= 0 }) else {
            throw NMSStoreError.queryFailed(
                "The Atlas pack manifest counts must be nonnegative integers."
            )
        }
        let requiredKeys: Set<String> = [
            "entities",
            "localizations_preferred",
            "recipes",
            "recipe_ingredients",
            "content_records",
        ]
        guard Set(counts.keys) == requiredKeys else {
            throw NMSStoreError.queryFailed("The Atlas pack manifest count keys are invalid.")
        }
        return counts
    }

    private static func isPlausibleRepository(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty else { return false }
        return true
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        let bytes = value.utf8
        guard bytes.count == length else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isISO8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
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
        guard let match = Self.ftsQuery(query), limit > 0 else { return [] }
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
            return try self.query(sql, parameters: parameters, map: Self.mapEntity)
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
                copy.ingredients = try self.ingredientsUnlocked(recipeID: recipe.recipeID)
                return copy
            }
        }
    }

    func searchRecipes(query searchText: String, kind: String?, limit: Int = 20) throws -> [Recipe] {
        let rawTokens = Self.searchTokens(searchText)
        let resolvedKind = kind ?? Self.recipeKind(in: rawTokens)
        let tokens = rawTokens.filter { !Self.recipeSearchGlue.contains($0) }
        guard !tokens.isEmpty || resolvedKind != nil, limit > 0 else { return [] }
        return try withLock {
            var sql = """
            select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                   r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                   r.source_ordinal, r.source_commit_sha,
                   coalesce(e.display_name, e.name, r.output_game_id)
              from nms_recipes r
              left join nms_entities e
                on e.entity_type = r.output_entity_type
               and e.game_id = r.output_game_id
             where 1 = 1
            """
            var parameters: [SQLValue] = []
            if let kind = resolvedKind {
                sql += " and r.recipe_kind = ?"
                parameters.append(.text(kind))
            }
            for token in tokens {
                sql += """
                 and lower(
                       coalesce(r.recipe_name, '') || ' ' ||
                       coalesce(e.display_name, e.name, '') || ' ' ||
                       r.output_game_id
                     ) like ? escape '\\'
                """
                parameters.append(.text("%\(Self.escapeLike(token))%"))
            }
            sql += " order by lower(coalesce(r.recipe_name, e.display_name, r.recipe_id)) limit ?"
            parameters.append(.int(limit))
            return try self.query(sql, parameters: parameters, map: Self.mapRecipe).map { recipe in
                var copy = recipe
                copy.ingredients = try self.ingredientsUnlocked(recipeID: recipe.recipeID)
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
                copy.ingredients = try self.ingredientsUnlocked(recipeID: recipe.recipeID)
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
                copy.ingredients = try self.ingredientsUnlocked(recipeID: recipe.recipeID)
                return copy
            }
        }
    }

    func content(dataset: String, id: String, sourceOrdinal: Int) throws -> ContentRecord? {
        try withLock {
            try query(
                """
                select dataset, external_id, source_ordinal, display_name,
                       payload, source_commit_sha
                  from nms_content_records
                 where dataset = ? and external_id = ? and source_ordinal = ?
                """,
                parameters: [.text(dataset), .text(id), .int(sourceOrdinal)]
            ) { stmt in
                ContentRecord(
                    dataset: Self.text(stmt, 0) ?? "",
                    externalID: Self.text(stmt, 1) ?? "",
                    sourceOrdinal: Int(sqlite3_column_int(stmt, 2)),
                    displayName: Self.text(stmt, 3),
                    payload: Self.text(stmt, 4) ?? "{}",
                    sourceCommitSHA: Self.text(stmt, 5) ?? ""
                )
            }.first
        }
    }

    func searchContent(query: String, dataset: String?, limit: Int = 20) throws -> [ContentRecord] {
        guard let match = Self.ftsQuery(query), limit > 0 else { return [] }
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
            return try self.query(sql, parameters: parameters) { stmt in
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
            let status: Int32
            switch parameter {
            case .text(let value):
                status = sqlite3_bind_text(stmt, slot, value, -1, SQLITE_TRANSIENT)
            case .int(let value):
                status = sqlite3_bind_int(stmt, slot, Int32(value))
            }
            guard status == SQLITE_OK else {
                throw NMSStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                rows.append(map(stmt))
            case SQLITE_DONE:
                return rows
            default:
                throw NMSStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
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

    static func ftsQuery(_ raw: String) -> String? {
        let tokens = searchTokens(raw)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    private static func searchTokens(_ raw: String) -> [String] {
        raw.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static let recipeSearchGlue: Set<String> = [
        "cook", "cooked", "cooking", "craft", "crafted", "crafting",
        "make", "making", "recipe", "recipes", "refine", "refined", "refiner", "refining",
    ]

    private static func recipeKind(in tokens: [String]) -> String? {
        if tokens.contains(where: { ["cook", "cooked", "cooking"].contains($0) }) {
            return "cooking"
        }
        if tokens.contains(where: { ["refine", "refined", "refiner", "refining"].contains($0) }) {
            return "refining"
        }
        if tokens.contains(where: { ["craft", "crafted", "crafting"].contains($0) }) {
            return "crafting"
        }
        return nil
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
