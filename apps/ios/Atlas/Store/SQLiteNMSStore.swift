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
    func recipesProducing(type: String, id: String, limit: Int) throws -> [Recipe]
    func recipesUsing(type: String, id: String) throws -> [Recipe]
    func recipesUsing(type: String, id: String, limit: Int) throws -> [Recipe]
    func content(dataset: String, id: String, sourceOrdinal: Int) throws -> ContentRecord?
    func contentRecords(dataset: String, limit: Int, offset: Int) throws -> [ContentRecord]
    func searchContent(query: String, dataset: String?, limit: Int) throws -> [ContentRecord]
    func specialistSummaries(_ query: SpecialistQuery) throws -> [SpecialistSummary]
    func specialistRecord(
        feature: SpecialistFeature,
        id: String,
        sourceOrdinal: Int
    ) throws -> SpecialistDetail?
    func specialistFilterOptions(feature: SpecialistFeature) throws -> SpecialistFilterOptions
}

final class SQLiteNMSStore: NMSStore, @unchecked Sendable {
    static let supportedPackSchemaVersion = 2

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
            guard manifest.packSchemaVersion == Self.supportedPackSchemaVersion else {
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
                       color_r, color_g, color_b, source_dataset, source_commit_sha,
                       icon_source_path
                  from nms_entities
                 where entity_type = ? and game_id = ?
                """,
                parameters: [.text(type), .text(id)],
                map: Self.mapEntity
            ).first
        }
    }

    func searchEntities(query: String, type: String?, limit: Int = 20) throws -> [Entity] {
        let tokens = Self.searchTokens(query)
        guard let match = Self.ftsQuery(query), !tokens.isEmpty, limit > 0 else { return [] }
        return try withLock {
            var metadataSQL = """
            select e.entity_type, e.game_id, e.name, e.display_name, e.subtitle, e.description,
                   e.category, e.subcategory, e.rarity, e.legality, e.base_value,
                   e.color_r, e.color_g, e.color_b, e.source_dataset, e.source_commit_sha,
                   e.icon_source_path
              from nms_entities e
             where 1 = 1
            """
            var metadataParameters: [SQLValue] = []
            if let type {
                metadataSQL += " and e.entity_type = ?"
                metadataParameters.append(.text(type))
            }
            Self.appendTokenPredicates(
                tokens,
                columns: [
                    "e.entity_type", "e.game_id", "e.name", "e.display_name",
                    "e.subtitle", "e.description", "e.category", "e.subcategory",
                    "e.rarity", "e.legality", "e.source_dataset",
                ],
                sql: &metadataSQL,
                parameters: &metadataParameters
            )
            metadataSQL += """
             order by case
                        when lower(coalesce(e.display_name, e.name, e.game_id)) = ? then 0
                        when lower(e.game_id) = ? then 1
                        when lower(e.entity_type) = ? then 2
                        else 3
                      end,
                      lower(coalesce(e.display_name, e.name, e.game_id))
             limit ?
            """
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            metadataParameters.append(.text(normalizedQuery))
            metadataParameters.append(.text(normalizedQuery))
            metadataParameters.append(.text(normalizedQuery))
            metadataParameters.append(.int(limit))
            let metadata = try self.query(
                metadataSQL,
                parameters: metadataParameters,
                map: Self.mapEntity
            )

            var ftsSQL = """
            select e.entity_type, e.game_id, e.name, e.display_name, e.subtitle, e.description,
                   e.category, e.subcategory, e.rarity, e.legality, e.base_value,
                   e.color_r, e.color_g, e.color_b, e.source_dataset, e.source_commit_sha,
                   e.icon_source_path
              from nms_entities_fts
              join nms_entities e
                on e.entity_type = nms_entities_fts.entity_type
               and e.game_id = nms_entities_fts.game_id
             where nms_entities_fts match ?
            """
            var ftsParameters: [SQLValue] = [.text(match)]
            if let type {
                ftsSQL += " and e.entity_type = ?"
                ftsParameters.append(.text(type))
            }
            ftsSQL += " order by bm25(nms_entities_fts, 10.0, 10.0, 3.0, 1.0) limit ?"
            ftsParameters.append(.int(limit))
            let indexed = try self.query(
                ftsSQL,
                parameters: ftsParameters,
                map: Self.mapEntity
            )
            return Self.uniquePrefix(
                metadata + indexed,
                limit: limit,
                key: { $0.id }
            )
        }
    }

    func entities(type: String, limit: Int = 100, offset: Int = 0) throws -> [Entity] {
        try withLock {
            try query(
                """
                select entity_type, game_id, name, display_name, subtitle, description,
                       category, subcategory, rarity, legality, base_value,
                       color_r, color_g, color_b, source_dataset, source_commit_sha,
                       icon_source_path
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
        try recipesProducing(type: type, id: id, limit: 10_000)
    }

    func recipesProducing(type: String, id: String, limit: Int) throws -> [Recipe] {
        guard limit > 0 else { return [] }
        return try withLock {
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
                 limit ?
                """,
                parameters: [.text(type), .text(id), .int(limit)],
                map: Self.mapRecipe
            ).map { recipe in
                var copy = recipe
                copy.ingredients = try self.ingredientsUnlocked(recipeID: recipe.recipeID)
                return copy
            }
        }
    }

    func recipesUsing(type: String, id: String) throws -> [Recipe] {
        try recipesUsing(type: type, id: id, limit: 10_000)
    }

    func recipesUsing(type: String, id: String, limit: Int) throws -> [Recipe] {
        guard limit > 0 else { return [] }
        return try withLock {
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
                 limit ?
                """,
                parameters: [.text(type), .text(id), .int(limit)],
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
                       payload, source_commit_sha, icon_source_path
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
                    sourceCommitSHA: Self.text(stmt, 5) ?? "",
                    iconSourcePath: Self.text(stmt, 6)
                )
            }.first
        }
    }

    func contentRecords(dataset: String, limit: Int = 100, offset: Int = 0) throws -> [ContentRecord] {
        guard limit > 0, offset >= 0 else { return [] }
        return try withLock {
            try query(
                """
                select dataset, external_id, source_ordinal, display_name,
                       payload, source_commit_sha, icon_source_path
                  from nms_content_records
                 where dataset = ?
                 order by lower(coalesce(display_name, external_id)), source_ordinal
                 limit ? offset ?
                """,
                parameters: [.text(dataset), .int(limit), .int(offset)],
                map: Self.mapContent
            )
        }
    }

    func searchContent(query: String, dataset: String?, limit: Int = 20) throws -> [ContentRecord] {
        let tokens = Self.searchTokens(query)
        guard let match = Self.ftsQuery(query), !tokens.isEmpty, limit > 0 else { return [] }
        return try withLock {
            var metadataSQL = """
            select c.dataset, c.external_id, c.source_ordinal, c.display_name,
                   c.payload, c.source_commit_sha, c.icon_source_path
              from nms_content_records c
             where 1 = 1
            """
            var metadataParameters: [SQLValue] = []
            if let dataset {
                metadataSQL += " and c.dataset = ?"
                metadataParameters.append(.text(dataset))
            }
            Self.appendTokenPredicates(
                tokens,
                columns: ["c.dataset", "c.external_id", "c.display_name"],
                sql: &metadataSQL,
                parameters: &metadataParameters
            )
            metadataSQL += """
             order by case
                        when lower(coalesce(c.display_name, c.external_id)) = ? then 0
                        when lower(c.external_id) = ? then 1
                        when lower(replace(c.dataset, '_', ' ')) = ? then 2
                        else 3
                      end,
                      lower(coalesce(c.display_name, c.external_id)), c.source_ordinal
             limit ?
            """
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            metadataParameters.append(.text(normalizedQuery))
            metadataParameters.append(.text(normalizedQuery))
            metadataParameters.append(.text(normalizedQuery))
            metadataParameters.append(.int(limit))
            let metadata = try self.query(
                metadataSQL,
                parameters: metadataParameters,
                map: Self.mapContent
            )

            var ftsSQL = """
            select c.dataset, c.external_id, c.source_ordinal, c.display_name,
                   c.payload, c.source_commit_sha, c.icon_source_path
              from nms_content_fts
              join nms_content_records c
                on c.dataset = nms_content_fts.dataset
               and c.external_id = nms_content_fts.external_id
               and c.source_ordinal = nms_content_fts.source_ordinal
             where nms_content_fts match ?
            """
            var ftsParameters: [SQLValue] = [.text(match)]
            if let dataset {
                ftsSQL += " and c.dataset = ?"
                ftsParameters.append(.text(dataset))
            }
            ftsSQL += " order by bm25(nms_content_fts, 5.0, 1.0) limit ?"
            ftsParameters.append(.int(limit))
            let indexed = try self.query(
                ftsSQL,
                parameters: ftsParameters,
                map: Self.mapContent
            )
            return Self.uniquePrefix(
                metadata + indexed,
                limit: limit,
                key: { $0.id }
            )
        }
    }

    func specialistSummaries(_ query: SpecialistQuery) throws -> [SpecialistSummary] {
        guard query.limit > 0, query.offset >= 0 else { return [] }
        return try withLock {
            switch query.feature {
            case .fish: return try listFishUnlocked(query)
            case .bait: return try listBaitUnlocked(query)
            case .buildingParts: return try listBuildingPartsUnlocked(query)
            case .shipParts: return try listShipPartsUnlocked(query)
            case .corvetteParts: return try listCorvettePartsUnlocked(query)
            case .fossils: return try listSimpleUnlocked(
                query,
                table: "nms_fossils",
                extraSelect: "category",
                categoryFilterColumn: "category"
            )
            case .legacyItems: return try listSimpleUnlocked(query, table: "nms_legacy_items")
            case .buildingBlueprints:
                return try listSimpleUnlocked(query, table: "nms_building_blueprints")
            case .specialPurchases:
                return try listSimpleUnlocked(query, table: "nms_special_purchases")
            case .specialRewards:
                return try listSimpleUnlocked(query, table: "nms_special_rewards")
            case .stories:
                return try listSimpleUnlocked(query, table: "nms_stories")
            }
        }
    }

    func specialistRecord(
        feature: SpecialistFeature,
        id: String,
        sourceOrdinal: Int
    ) throws -> SpecialistDetail? {
        try withLock {
            switch feature {
            case .fish: return try fishDetailUnlocked(id: id, sourceOrdinal: sourceOrdinal)
            case .bait: return try baitDetailUnlocked(id: id, sourceOrdinal: sourceOrdinal)
            case .buildingParts:
                return try buildingPartDetailUnlocked(id: id, sourceOrdinal: sourceOrdinal)
            case .shipParts: return try shipPartDetailUnlocked(id: id, sourceOrdinal: sourceOrdinal)
            case .corvetteParts:
                return try corvettePartDetailUnlocked(id: id, sourceOrdinal: sourceOrdinal)
            case .fossils:
                return try simpleDetailUnlocked(
                    feature: feature,
                    table: "nms_fossils",
                    id: id,
                    sourceOrdinal: sourceOrdinal,
                    extraColumns: [("category", "Category")]
                )
            case .legacyItems:
                return try simpleDetailUnlocked(
                    feature: feature,
                    table: "nms_legacy_items",
                    id: id,
                    sourceOrdinal: sourceOrdinal,
                    extraColumns: [("converts_to", "Converts to"), ("conversion_ratio", "Conversion ratio")]
                )
            case .buildingBlueprints:
                return try simpleDetailUnlocked(
                    feature: feature,
                    table: "nms_building_blueprints",
                    id: id,
                    sourceOrdinal: sourceOrdinal
                )
            case .specialPurchases:
                return try simpleDetailUnlocked(
                    feature: feature,
                    table: "nms_special_purchases",
                    id: id,
                    sourceOrdinal: sourceOrdinal
                )
            case .specialRewards:
                return try rewardDetailUnlocked(id: id, sourceOrdinal: sourceOrdinal)
            case .stories:
                return try storyDetailUnlocked(id: id, sourceOrdinal: sourceOrdinal)
            }
        }
    }

    func specialistFilterOptions(feature: SpecialistFeature) throws -> SpecialistFilterOptions {
        try withLock {
            var options = SpecialistFilterOptions()
            switch feature {
            case .fish:
                options.times = try distinctUnlocked("nms_fish", column: "time_of_day")
                options.sizes = try distinctUnlocked("nms_fish", column: "size")
                options.qualities = try distinctUnlocked("nms_fish", column: "quality")
                options.biomes = try distinctUnlocked("nms_fish_biomes", column: "biome")
            case .bait:
                options.usedFor = try distinctUnlocked("nms_bait", column: "used_for")
            case .shipParts:
                options.shipTypes = try distinctUnlocked("nms_ship_parts", column: "ship_type")
                options.categories = try distinctUnlocked("nms_ship_parts", column: "category")
            case .buildingParts:
                options.categories = try distinctUnlocked("nms_building_parts", column: "wiki_category")
            case .corvetteParts:
                options.categories = try distinctUnlocked(
                    "nms_corvette_part_categories",
                    column: "category"
                )
            case .fossils:
                options.categories = try distinctUnlocked("nms_fossils", column: "category")
            default:
                break
            }
            return options
        }
    }

    private func listFishUnlocked(_ query: SpecialistQuery) throws -> [SpecialistSummary] {
        var sql = """
        select distinct f.external_id, f.source_ordinal, f.title, f.subtitle,
               f.quality, f.size, f.time_of_day, f.needs_storm, f.icon_source_path,
               f.requires_mission
          from nms_fish f
        """
        var parameters: [SQLValue] = []
        if query.biome != nil {
            sql += """
              join nms_fish_biomes b
                on b.external_id = f.external_id
               and b.source_ordinal = f.source_ordinal
            """
        }
        sql += " where 1 = 1"
        appendSearch(query.search, columns: ["f.title", "f.external_id", "f.subtitle"], sql: &sql, parameters: &parameters)
        if let timeOfDay = query.timeOfDay {
            sql += " and f.time_of_day = ?"
            parameters.append(.text(timeOfDay))
        }
        if let size = query.size {
            sql += " and f.size = ?"
            parameters.append(.text(size))
        }
        if let quality = query.quality {
            sql += " and f.quality = ?"
            parameters.append(.text(quality))
        }
        if let needsStorm = query.needsStorm {
            sql += " and f.needs_storm = ?"
            parameters.append(.int(needsStorm ? 1 : 0))
        }
        if let biome = query.biome {
            sql += " and b.biome = ?"
            parameters.append(.text(biome))
        }
        sql += " order by lower(coalesce(f.title, f.external_id)) limit ? offset ?"
        parameters.append(.int(query.limit))
        parameters.append(.int(query.offset))
        return try self.query(sql, parameters: parameters) { stmt in
            var badges: [String] = []
            if let quality = Self.text(stmt, 4) { badges.append(quality) }
            if let size = Self.text(stmt, 5) { badges.append(size) }
            if let time = Self.text(stmt, 6) { badges.append(time) }
            if Self.intValue(stmt, 7) == 1 { badges.append("Storm") }
            if Self.text(stmt, 9) != nil { badges.append("Mission") }
            return SpecialistSummary(
                feature: .fish,
                externalID: Self.text(stmt, 0) ?? "",
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? Self.text(stmt, 0) ?? "",
                subtitle: Self.text(stmt, 3),
                iconSourcePath: Self.text(stmt, 8),
                badges: badges,
                notEnabled: false
            )
        }
    }

    private func listBaitUnlocked(_ query: SpecialistQuery) throws -> [SpecialistSummary] {
        var sql = """
        select external_id, source_ordinal, title, used_for, rarity_percent,
               size_percent, source_kind, icon_source_path
          from nms_bait
         where 1 = 1
        """
        var parameters: [SQLValue] = []
        appendSearch(query.search, columns: ["title", "external_id"], sql: &sql, parameters: &parameters)
        if let usedFor = query.usedFor {
            sql += " and used_for = ?"
            parameters.append(.text(usedFor))
        }
        sql += " order by lower(coalesce(title, external_id)) limit ? offset ?"
        parameters.append(.int(query.limit))
        parameters.append(.int(query.offset))
        return try self.query(sql, parameters: parameters) { stmt in
            var badges: [String] = []
            if let usedFor = Self.text(stmt, 3) { badges.append(usedFor) }
            if let rarity = Self.text(stmt, 4) { badges.append("Rarity \(rarity)%") }
            if let size = Self.text(stmt, 5) { badges.append("Size \(size)%") }
            return SpecialistSummary(
                feature: .bait,
                externalID: Self.text(stmt, 0) ?? "",
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? Self.text(stmt, 0) ?? "",
                subtitle: Self.text(stmt, 6),
                iconSourcePath: Self.text(stmt, 7),
                badges: badges,
                notEnabled: false
            )
        }
    }

    private func listBuildingPartsUnlocked(_ query: SpecialistQuery) throws -> [SpecialistSummary] {
        try listPartsUnlocked(
            query,
            feature: .buildingParts,
            table: "nms_building_parts",
            categoryColumn: "wiki_category"
        )
    }

    private func listCorvettePartsUnlocked(_ query: SpecialistQuery) throws -> [SpecialistSummary] {
        var sql = """
        select distinct p.external_id, p.source_ordinal, p.title, p.wiki_category,
               p.not_enabled, p.icon_source_path
          from nms_corvette_parts p
        """
        var parameters: [SQLValue] = []
        if query.category != nil {
            sql += """
              join nms_corvette_part_categories c
                on c.external_id = p.external_id
               and c.source_ordinal = p.source_ordinal
            """
        }
        sql += " where 1 = 1"
        appendSearch(query.search, columns: ["p.title", "p.external_id"], sql: &sql, parameters: &parameters)
        if !query.includeNotEnabled {
            sql += " and p.not_enabled = 0"
        }
        if let category = query.category {
            sql += " and c.category = ?"
            parameters.append(.text(category))
        }
        sql += " order by lower(coalesce(p.title, p.external_id)) limit ? offset ?"
        parameters.append(.int(query.limit))
        parameters.append(.int(query.offset))
        return try self.query(sql, parameters: parameters) { stmt in
            let notEnabled = sqlite3_column_int(stmt, 4) != 0
            var badges: [String] = []
            if let category = Self.text(stmt, 3) { badges.append(category) }
            if notEnabled { badges.append("Not enabled") }
            return SpecialistSummary(
                feature: .corvetteParts,
                externalID: Self.text(stmt, 0) ?? "",
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? Self.text(stmt, 0) ?? "",
                subtitle: nil,
                iconSourcePath: Self.text(stmt, 5),
                badges: badges,
                notEnabled: notEnabled
            )
        }
    }

    private func listPartsUnlocked(
        _ query: SpecialistQuery,
        feature: SpecialistFeature,
        table: String,
        categoryColumn: String
    ) throws -> [SpecialistSummary] {
        var sql = """
        select external_id, source_ordinal, title, \(categoryColumn), not_enabled, icon_source_path
          from \(table)
         where 1 = 1
        """
        var parameters: [SQLValue] = []
        appendSearch(query.search, columns: ["title", "external_id"], sql: &sql, parameters: &parameters)
        if !query.includeNotEnabled {
            sql += " and not_enabled = 0"
        }
        if let category = query.category {
            sql += " and \(categoryColumn) = ?"
            parameters.append(.text(category))
        }
        sql += " order by lower(coalesce(title, external_id)) limit ? offset ?"
        parameters.append(.int(query.limit))
        parameters.append(.int(query.offset))
        return try self.query(sql, parameters: parameters) { stmt in
            let notEnabled = sqlite3_column_int(stmt, 4) != 0
            var badges: [String] = []
            if let category = Self.text(stmt, 3) { badges.append(category) }
            if notEnabled { badges.append("Not enabled") }
            return SpecialistSummary(
                feature: feature,
                externalID: Self.text(stmt, 0) ?? "",
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? Self.text(stmt, 0) ?? "",
                subtitle: nil,
                iconSourcePath: Self.text(stmt, 5),
                badges: badges,
                notEnabled: notEnabled
            )
        }
    }

    private func listShipPartsUnlocked(_ query: SpecialistQuery) throws -> [SpecialistSummary] {
        var sql = """
        select external_id, source_ordinal, title, subtitle, ship_type, category,
               rarity, icon_source_path
          from nms_ship_parts
         where 1 = 1
        """
        var parameters: [SQLValue] = []
        appendSearch(
            query.search,
            columns: ["title", "external_id", "subtitle"],
            sql: &sql,
            parameters: &parameters
        )
        if let shipType = query.shipType {
            sql += " and ship_type = ?"
            parameters.append(.text(shipType))
        }
        if let category = query.category {
            sql += " and category = ?"
            parameters.append(.text(category))
        }
        sql += " order by lower(coalesce(title, external_id)) limit ? offset ?"
        parameters.append(.int(query.limit))
        parameters.append(.int(query.offset))
        return try self.query(sql, parameters: parameters) { stmt in
            var badges: [String] = []
            if let type = Self.text(stmt, 4) { badges.append(type) }
            if let category = Self.text(stmt, 5) { badges.append(category) }
            if let rarity = Self.text(stmt, 6) { badges.append(rarity) }
            return SpecialistSummary(
                feature: .shipParts,
                externalID: Self.text(stmt, 0) ?? "",
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? Self.text(stmt, 0) ?? "",
                subtitle: Self.text(stmt, 3),
                iconSourcePath: Self.text(stmt, 7),
                badges: badges,
                notEnabled: false
            )
        }
    }

    private func listSimpleUnlocked(
        _ query: SpecialistQuery,
        table: String,
        extraSelect: String? = nil,
        categoryFilterColumn: String? = nil
    ) throws -> [SpecialistSummary] {
        let extra = extraSelect.map { ", \($0)" } ?? ""
        var sql = """
        select external_id, source_ordinal, title, icon_source_path\(extra)
          from \(table)
         where 1 = 1
        """
        var parameters: [SQLValue] = []
        appendSearch(query.search, columns: ["title", "external_id"], sql: &sql, parameters: &parameters)
        if let column = categoryFilterColumn, let category = query.category {
            sql += " and \(column) = ?"
            parameters.append(.text(category))
        }
        sql += " order by lower(coalesce(title, external_id)) limit ? offset ?"
        parameters.append(.int(query.limit))
        parameters.append(.int(query.offset))
        return try self.query(sql, parameters: parameters) { stmt in
            var badges: [String] = []
            if extraSelect != nil, let extra = Self.text(stmt, 4) {
                badges.append(extra)
            }
            return SpecialistSummary(
                feature: query.feature,
                externalID: Self.text(stmt, 0) ?? "",
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? Self.text(stmt, 0) ?? "",
                subtitle: nil,
                iconSourcePath: Self.text(stmt, 3),
                badges: badges,
                notEnabled: false
            )
        }
    }

    private func fishDetailUnlocked(id: String, sourceOrdinal: Int) throws -> SpecialistDetail? {
        let rows: [SpecialistDetail] = try query(
            """
            select external_id, source_ordinal, title, subtitle, description, quality, size,
                   time_of_day, needs_storm, requires_mission, mission_seed, icon_source_path,
                   extra_json, product_id
              from nms_fish
             where external_id = ? and source_ordinal = ?
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            var fields: [ContentField] = []
            Self.appendField(&fields, key: "product_id", label: "Product ID", value: Self.text(stmt, 13))
            Self.appendField(&fields, key: "description", label: "Description", value: Self.text(stmt, 4))
            Self.appendField(&fields, key: "quality", label: "Quality", value: Self.text(stmt, 5))
            Self.appendField(&fields, key: "size", label: "Size", value: Self.text(stmt, 6))
            Self.appendField(&fields, key: "time_of_day", label: "Time", value: Self.text(stmt, 7))
            if let storm = Self.intValue(stmt, 8) {
                Self.appendField(&fields, key: "needs_storm", label: "Needs storm", value: storm == 1 ? "true" : "false")
            }
            Self.appendField(&fields, key: "requires_mission", label: "Requires mission", value: Self.text(stmt, 9))
            Self.appendField(&fields, key: "mission_seed", label: "Mission seed", value: Self.text(stmt, 10))
            let summary = SpecialistSummary(
                feature: .fish,
                externalID: Self.text(stmt, 0) ?? id,
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? id,
                subtitle: Self.text(stmt, 3),
                iconSourcePath: Self.text(stmt, 11),
                badges: fields.compactMap { field in
                    ["Quality", "Size", "Time"].contains(field.label) ? field.value : nil
                },
                notEnabled: false
            )
            return SpecialistDetail(
                summary: summary,
                fields: fields,
                biomes: [],
                requirements: [],
                categories: [],
                rewardSources: [],
                storyPages: [],
                extraFields: Self.extraFields(Self.text(stmt, 12) ?? "{}"),
                prettyPayload: ""
            )
        }
        guard var detail = rows.first else { return nil }
        detail.biomes = try query(
            """
            select biome from nms_fish_biomes
             where external_id = ? and source_ordinal = ?
             order by position
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            Self.text(stmt, 0) ?? ""
        }.filter { !$0.isEmpty }
        detail.prettyPayload = try payloadUnlocked(dataset: "fish", id: id, sourceOrdinal: sourceOrdinal)
        return detail
    }

    private func baitDetailUnlocked(id: String, sourceOrdinal: Int) throws -> SpecialistDetail? {
        let rows: [SpecialistDetail] = try query(
            """
            select external_id, source_ordinal, title, used_for, rarity_percent, size_percent,
                   source_kind, icon_source_path, extra_json
              from nms_bait
             where external_id = ? and source_ordinal = ?
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            var fields: [ContentField] = []
            Self.appendField(&fields, key: "used_for", label: "Used for", value: Self.text(stmt, 3))
            Self.appendField(&fields, key: "rarity_percent", label: "Rarity %", value: Self.text(stmt, 4))
            Self.appendField(&fields, key: "size_percent", label: "Size %", value: Self.text(stmt, 5))
            Self.appendField(&fields, key: "source_kind", label: "Source", value: Self.text(stmt, 6))
            let summary = SpecialistSummary(
                feature: .bait,
                externalID: Self.text(stmt, 0) ?? id,
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? id,
                subtitle: Self.text(stmt, 3),
                iconSourcePath: Self.text(stmt, 7),
                badges: [Self.text(stmt, 3)].compactMap { $0 },
                notEnabled: false
            )
            return SpecialistDetail(
                summary: summary,
                fields: fields,
                biomes: [],
                requirements: [],
                categories: [],
                rewardSources: [],
                storyPages: [],
                extraFields: Self.extraFields(Self.text(stmt, 8) ?? "{}"),
                prettyPayload: ""
            )
        }
        guard var detail = rows.first else { return nil }
        detail.prettyPayload = try payloadUnlocked(dataset: "bait", id: id, sourceOrdinal: sourceOrdinal)
        return detail
    }

    private func buildingPartDetailUnlocked(id: String, sourceOrdinal: Int) throws -> SpecialistDetail? {
        try partDetailUnlocked(
            feature: .buildingParts,
            table: "nms_building_parts",
            requirementsTable: "nms_building_part_requirements",
            id: id,
            sourceOrdinal: sourceOrdinal
        )
    }

    private func corvettePartDetailUnlocked(id: String, sourceOrdinal: Int) throws -> SpecialistDetail? {
        guard var detail = try partDetailUnlocked(
            feature: .corvetteParts,
            table: "nms_corvette_parts",
            requirementsTable: "nms_corvette_part_requirements",
            id: id,
            sourceOrdinal: sourceOrdinal
        ) else { return nil }
        detail.categories = try query(
            """
            select category from nms_corvette_part_categories
             where external_id = ? and source_ordinal = ?
             order by position
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            Self.text(stmt, 0) ?? ""
        }.filter { !$0.isEmpty }
        return detail
    }

    private func partDetailUnlocked(
        feature: SpecialistFeature,
        table: String,
        requirementsTable: String,
        id: String,
        sourceOrdinal: Int
    ) throws -> SpecialistDetail? {
        let rows: [SpecialistDetail] = try query(
            """
            select external_id, source_ordinal, title, wiki_category, not_enabled,
                   icon_source_path, extra_json
              from \(table)
             where external_id = ? and source_ordinal = ?
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            let notEnabled = sqlite3_column_int(stmt, 4) != 0
            var fields: [ContentField] = []
            Self.appendField(&fields, key: "wiki_category", label: "Category", value: Self.text(stmt, 3))
            Self.appendField(
                &fields,
                key: "not_enabled",
                label: "Not enabled",
                value: notEnabled ? "true" : "false"
            )
            let summary = SpecialistSummary(
                feature: feature,
                externalID: Self.text(stmt, 0) ?? id,
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? id,
                subtitle: Self.text(stmt, 3),
                iconSourcePath: Self.text(stmt, 5),
                badges: [Self.text(stmt, 3)].compactMap { $0 },
                notEnabled: notEnabled
            )
            return SpecialistDetail(
                summary: summary,
                fields: fields,
                biomes: [],
                requirements: [],
                categories: [],
                rewardSources: [],
                storyPages: [],
                extraFields: Self.extraFields(Self.text(stmt, 6) ?? "{}"),
                prettyPayload: ""
            )
        }
        guard var detail = rows.first else { return nil }
        detail.requirements = try requirementsUnlocked(
            table: requirementsTable,
            id: id,
            sourceOrdinal: sourceOrdinal
        )
        detail.prettyPayload = try payloadUnlocked(
            dataset: feature.dataset,
            id: id,
            sourceOrdinal: sourceOrdinal
        )
        return detail
    }

    private func shipPartDetailUnlocked(id: String, sourceOrdinal: Int) throws -> SpecialistDetail? {
        let rows: [SpecialistDetail] = try query(
            """
            select external_id, source_ordinal, title, subtitle, ship_type, category,
                   rarity, base_value, icon_source_path, extra_json
              from nms_ship_parts
             where external_id = ? and source_ordinal = ?
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            var fields: [ContentField] = []
            Self.appendField(&fields, key: "ship_type", label: "Type", value: Self.text(stmt, 4))
            Self.appendField(&fields, key: "category", label: "Category", value: Self.text(stmt, 5))
            Self.appendField(&fields, key: "rarity", label: "Rarity", value: Self.text(stmt, 6))
            Self.appendField(&fields, key: "base_value", label: "Base value", value: Self.text(stmt, 7))
            let summary = SpecialistSummary(
                feature: .shipParts,
                externalID: Self.text(stmt, 0) ?? id,
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? id,
                subtitle: Self.text(stmt, 3),
                iconSourcePath: Self.text(stmt, 8),
                badges: [Self.text(stmt, 4), Self.text(stmt, 5)].compactMap { $0 },
                notEnabled: false
            )
            return SpecialistDetail(
                summary: summary,
                fields: fields,
                biomes: [],
                requirements: [],
                categories: [],
                rewardSources: [],
                storyPages: [],
                extraFields: Self.extraFields(Self.text(stmt, 9) ?? "{}"),
                prettyPayload: ""
            )
        }
        guard var detail = rows.first else { return nil }
        detail.prettyPayload = try payloadUnlocked(
            dataset: "ship_parts",
            id: id,
            sourceOrdinal: sourceOrdinal
        )
        return detail
    }

    private func rewardDetailUnlocked(id: String, sourceOrdinal: Int) throws -> SpecialistDetail? {
        guard var detail = try simpleDetailUnlocked(
            feature: .specialRewards,
            table: "nms_special_rewards",
            id: id,
            sourceOrdinal: sourceOrdinal
        ) else { return nil }
        detail.rewardSources = try query(
            """
            select source_label from nms_special_reward_sources
             where external_id = ? and source_ordinal = ?
             order by position
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            Self.text(stmt, 0) ?? ""
        }.filter { !$0.isEmpty }
        return detail
    }

    private func storyDetailUnlocked(id: String, sourceOrdinal: Int) throws -> SpecialistDetail? {
        guard var detail = try simpleDetailUnlocked(
            feature: .stories,
            table: "nms_stories",
            id: id,
            sourceOrdinal: sourceOrdinal
        ) else { return nil }
        let pages: [(Int, String?)] = try query(
            """
            select position, title from nms_story_pages
             where external_id = ? and source_ordinal = ?
             order by position
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            (Int(sqlite3_column_int(stmt, 0)), Self.text(stmt, 1))
        }
        let entries: [SpecialistStoryEntry] = try query(
            """
            select page_position, position, title, body from nms_story_entries
             where external_id = ? and source_ordinal = ?
             order by page_position, position
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            SpecialistStoryEntry(
                pagePosition: Int(sqlite3_column_int(stmt, 0)),
                position: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2),
                body: Self.text(stmt, 3)
            )
        }
        detail.storyPages = pages.map { position, title in
            SpecialistStoryPage(
                position: position,
                title: title,
                entries: entries.filter { $0.pagePosition == position }
            )
        }
        return detail
    }

    private func simpleDetailUnlocked(
        feature: SpecialistFeature,
        table: String,
        id: String,
        sourceOrdinal: Int,
        extraColumns: [(column: String, label: String)] = []
    ) throws -> SpecialistDetail? {
        let extras = extraColumns.map(\.column)
        let extraSQL = extras.isEmpty ? "" : ", " + extras.joined(separator: ", ")
        let rows: [SpecialistDetail] = try query(
            """
            select external_id, source_ordinal, title, icon_source_path, extra_json\(extraSQL)
              from \(table)
             where external_id = ? and source_ordinal = ?
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            var fields: [ContentField] = []
            for (index, column) in extraColumns.enumerated() {
                Self.appendField(
                    &fields,
                    key: column.column,
                    label: column.label,
                    value: Self.text(stmt, Int32(5 + index))
                )
            }
            let summary = SpecialistSummary(
                feature: feature,
                externalID: Self.text(stmt, 0) ?? id,
                sourceOrdinal: Int(sqlite3_column_int(stmt, 1)),
                title: Self.text(stmt, 2) ?? id,
                subtitle: fields.first?.value,
                iconSourcePath: Self.text(stmt, 3),
                badges: fields.map(\.value),
                notEnabled: false
            )
            return SpecialistDetail(
                summary: summary,
                fields: fields,
                biomes: [],
                requirements: [],
                categories: [],
                rewardSources: [],
                storyPages: [],
                extraFields: Self.extraFields(Self.text(stmt, 4) ?? "{}"),
                prettyPayload: ""
            )
        }
        guard var detail = rows.first else { return nil }
        detail.prettyPayload = try payloadUnlocked(
            dataset: feature.dataset,
            id: id,
            sourceOrdinal: sourceOrdinal
        )
        return detail
    }

    private func requirementsUnlocked(
        table: String,
        id: String,
        sourceOrdinal: Int
    ) throws -> [SpecialistRequirement] {
        try query(
            """
            select r.position, r.entity_type, r.game_id, r.amount,
                   coalesce(e.display_name, e.name, r.game_id)
              from \(table) r
              left join nms_entities e
                on e.entity_type = r.entity_type
               and e.game_id = r.game_id
             where r.external_id = ? and r.source_ordinal = ?
             order by r.position
            """,
            parameters: [.text(id), .int(sourceOrdinal)]
        ) { stmt in
            SpecialistRequirement(
                position: Int(sqlite3_column_int(stmt, 0)),
                entityType: Self.text(stmt, 1),
                gameID: Self.text(stmt, 2),
                amount: Self.text(stmt, 3),
                title: Self.text(stmt, 4)
            )
        }
    }

    private func payloadUnlocked(dataset: String, id: String, sourceOrdinal: Int) throws -> String {
        let rows: [String] = try query(
            """
            select payload from nms_content_records
             where dataset = ? and external_id = ? and source_ordinal = ?
            """,
            parameters: [.text(dataset), .text(id), .int(sourceOrdinal)]
        ) { stmt in
            Self.text(stmt, 0) ?? "{}"
        }
        let payload = rows.first ?? "{}"
        return ContentDetailPresenter.present(payload: payload).prettyPayload
    }

    private func distinctUnlocked(_ table: String, column: String) throws -> [String] {
        try query(
            """
            select distinct \(column) from \(table)
             where \(column) is not null and \(column) <> ''
             order by lower(\(column))
            """,
            parameters: []
        ) { stmt in
            Self.text(stmt, 0) ?? ""
        }.filter { !$0.isEmpty }
    }

    private func appendSearch(
        _ search: String,
        columns: [String],
        sql: inout String,
        parameters: inout [SQLValue]
    ) {
        let tokens = Self.searchTokens(search)
        guard !tokens.isEmpty else { return }
        Self.appendTokenPredicates(tokens, columns: columns, sql: &sql, parameters: &parameters)
    }

    private static func appendField(
        _ fields: inout [ContentField],
        key: String,
        label: String,
        value: String?
    ) {
        guard let value, !value.isEmpty else { return }
        fields.append(ContentField(key: key, label: label, value: value))
    }

    private static func extraFields(_ json: String) -> [ContentField] {
        ContentDetailPresenter.present(payload: json).fields
    }

    private static func intValue(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, index))
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
            sourceCommitSHA: text(stmt, 15) ?? "",
            iconSourcePath: text(stmt, 16)
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

    private static func mapContent(_ stmt: OpaquePointer) -> ContentRecord {
        ContentRecord(
            dataset: text(stmt, 0) ?? "",
            externalID: text(stmt, 1) ?? "",
            sourceOrdinal: Int(sqlite3_column_int(stmt, 2)),
            displayName: text(stmt, 3),
            payload: text(stmt, 4) ?? "{}",
            sourceCommitSHA: text(stmt, 5) ?? "",
            iconSourcePath: text(stmt, 6)
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

    private static func appendTokenPredicates(
        _ tokens: [String],
        columns: [String],
        sql: inout String,
        parameters: inout [SQLValue]
    ) {
        for token in tokens {
            let predicates = columns.map { column in
                "lower(coalesce(\(column), '')) like ? escape '\\'"
            }
            sql += " and (\(predicates.joined(separator: " or ")))"
            let value = "%\(escapeLike(token))%"
            parameters.append(contentsOf: repeatElement(.text(value), count: columns.count))
        }
    }

    private static func uniquePrefix<T>(
        _ values: [T],
        limit: Int,
        key: (T) -> String
    ) -> [T] {
        var seen: Set<String> = []
        var result: [T] = []
        for value in values where seen.insert(key(value)).inserted {
            result.append(value)
            if result.count == limit { break }
        }
        return result
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
