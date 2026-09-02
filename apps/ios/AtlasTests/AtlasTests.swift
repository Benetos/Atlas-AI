import SQLite3
import XCTest
@testable import Atlas

final class AtlasQueryPlanTests: XCTestCase {
    func testFerriteDustUsesPrompt() {
        let plan = AtlasQueryPlan(prompt: "What is Ferrite Dust for?")

        XCTAssertEqual(plan.source, .local)
        XCTAssertEqual(plan.goal, .uses)
        XCTAssertNil(plan.operation)
        XCTAssertEqual(plan.localQuery, "Ferrite Dust")
        XCTAssertTrue(plan.shouldSearchRecipes)
    }

    func testCircuitBoardRecipePrompt() {
        let plan = AtlasQueryPlan(prompt: "Circuit Board recipe")

        XCTAssertEqual(plan.source, .local)
        XCTAssertEqual(plan.goal, .recipe)
        XCTAssertNil(plan.operation)
        XCTAssertEqual(plan.localQuery, "Circuit Board")
        XCTAssertTrue(plan.shouldSearchRecipes)
    }

    func testRefiningCarbonPrompt() {
        let plan = AtlasQueryPlan(prompt: "Refining Carbon")

        XCTAssertEqual(plan.source, .local)
        XCTAssertEqual(plan.goal, .recipe)
        XCTAssertEqual(plan.operation, .refining)
        XCTAssertEqual(plan.localQuery, "Carbon")
        XCTAssertEqual(plan.recipeKind, "refining")
    }

    func testBroadCookingPrompt() {
        let plan = AtlasQueryPlan(prompt: "How do I cook food?")

        XCTAssertEqual(plan.source, .local)
        XCTAssertEqual(plan.goal, .browseRecipes)
        XCTAssertEqual(plan.operation, .cooking)
        XCTAssertEqual(plan.localQuery, "food")
        XCTAssertTrue(plan.shouldBrowseRecipes)
    }

    func testCurrentExpeditionPromptUsesWeb() {
        let plan = AtlasQueryPlan(
            prompt: "Search the web for current No Man's Sky expedition"
        )

        XCTAssertEqual(plan.source, .web)
        XCTAssertEqual(plan.localQuery, "expedition")
        XCTAssertEqual(plan.externalQuery, "current No Man's Sky expedition")
        XCTAssertTrue(plan.requestsWeb)
    }

    func testLiveAtlasRequiresExplicitSourceIntent() {
        let ordinary = AtlasQueryPlan(prompt: "What is Ferrite Dust for?")
        let live = AtlasQueryPlan(prompt: "Search live Atlas for Ferrite Dust")

        XCTAssertEqual(ordinary.source, .local)
        XCTAssertFalse(ordinary.requestsLive)
        XCTAssertEqual(live.source, .live)
        XCTAssertTrue(live.requestsLive)
        XCTAssertEqual(live.localQuery, "Ferrite Dust")

        let ordinaryUse = AtlasQueryPlan(prompt: "Where does this creature live?")
        XCTAssertEqual(ordinaryUse.source, .local)
        XCTAssertFalse(ordinaryUse.requestsLive)
    }
}

final class OfflineAtlasTests: XCTestCase {
    func testPreviewSQLiteQueriesCanonicalData() throws {
        let store = try previewStore()

        let manifest = try store.manifest()
        XCTAssertEqual(manifest.packSchemaVersion, 1)
        XCTAssertFalse(manifest.sourceCommitSHA.isEmpty)

        let ferrite = try store.searchEntities(
            query: "Ferrite Dust",
            type: nil,
            limit: 8
        )
        XCTAssertTrue(ferrite.contains { $0.title == "Ferrite Dust" })

        let circuitBoard = try store.searchRecipes(
            query: "Circuit Board",
            kind: nil,
            limit: 8
        )
        XCTAssertTrue(circuitBoard.contains {
            $0.recipeKind == "crafting" && $0.outputGameID == "CIRCUITBOARD"
        })

        let cooking = try store.recipes(kind: "cooking", limit: 8, offset: 0)
        XCTAssertFalse(cooking.isEmpty)
    }

    func testPreviewPackPassesIntegrityCountsAndReadOnlyChecks() throws {
        let store = try previewStore()
        let manifest = try store.manifest()
        let recordedCounts = try XCTUnwrap(
            manifest.countsJSON.data(using: .utf8).flatMap {
                try? JSONDecoder().decode([String: Int].self, from: $0)
            }
        )

        XCTAssertEqual(try store.databaseCounts(), recordedCounts)
        XCTAssertNoThrow(try store.validateIntegrity())
        XCTAssertNoThrow(try store.validateReadOnlyBoundary())
    }

    func testManifestRequiresExactlyOneRow() throws {
        let url = try mutablePreviewURL()
        try execute(
            "insert into pack_manifest select * from pack_manifest",
            at: url
        )

        let store = try SQLiteNMSStore(fileURL: url)
        XCTAssertThrowsError(try store.manifest()) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one manifest row"))
        }
    }

    func testManifestRejectsUnsupportedVersionsAndInvalidSourceSHA() throws {
        try assertManifestRejected(
            after: "update pack_manifest set pack_schema_version = 2",
            containing: "unsupported schema version"
        )
        try assertManifestRejected(
            after: "update pack_manifest set contract_version = 2",
            containing: "unsupported contract version"
        )
        try assertManifestRejected(
            after: "update pack_manifest set source_commit_sha = 'not-a-commit'",
            containing: "invalid source commit SHA"
        )
        try assertManifestRejected(
            after: "update pack_manifest set source_repository = 'not-a-url'",
            containing: "invalid source repository"
        )
        try assertManifestRejected(
            after: "update pack_manifest set input_manifest_sha256 = 'not-a-digest'",
            containing: "invalid input manifest SHA-256"
        )
    }

    func testManifestRejectsInvalidOrMismatchedCounts() throws {
        try assertManifestRejected(
            after: """
            update pack_manifest
               set counts_json = '{"content_records":1,"entities":-1,"localizations_preferred":1,"recipe_ingredients":3,"recipes":3}'
            """,
            containing: "nonnegative integers"
        )
        try assertManifestRejected(
            after: """
            update pack_manifest
               set counts_json = '{"content_records":1,"entities":4,"localizations_preferred":1,"recipe_ingredients":3,"recipes":3}'
            """,
            containing: "do not match"
        )
        try assertManifestRejected(
            after: """
            update pack_manifest
               set counts_json = '{"content_records":1,"entities":"3","localizations_preferred":1,"recipe_ingredients":3,"recipes":3}'
            """,
            containing: "nonnegative integers"
        )
    }

    func testManifestRejectsIncompleteFTSIndex() throws {
        let url = try mutablePreviewURL()
        try execute(
            "delete from nms_entities_fts where rowid = (select min(rowid) from nms_entities_fts)",
            at: url
        )

        let store = try SQLiteNMSStore(fileURL: url)
        XCTAssertThrowsError(try store.manifest()) { error in
            XCTAssertTrue(error.localizedDescription.contains("FTS row count"))
        }
    }

    func testManifestRejectsRowsFromAnotherSourceCommit() throws {
        let url = try mutablePreviewURL()
        try execute(
            "update nms_entities set source_commit_sha = '0000000000000000000000000000000000000000' where rowid = (select min(rowid) from nms_entities)",
            at: url
        )

        let store = try SQLiteNMSStore(fileURL: url)
        XCTAssertThrowsError(try store.manifest()) { error in
            XCTAssertTrue(error.localizedDescription.contains("different source commit"))
        }
    }

    func testIntegrityRejectsBrokenForeignKey() throws {
        let url = try mutablePreviewURL()
        try execute(
            "update nms_recipes set output_game_id = 'MISSING_ENTITY' where rowid = (select min(rowid) from nms_recipes)",
            at: url
        )

        let store = try SQLiteNMSStore(fileURL: url)
        XCTAssertThrowsError(try store.validateIntegrity()) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid relationships"))
        }
    }

    func testRecipeQueriesPropagateIngredientTableFailures() throws {
        let url = try mutablePreviewURL()
        try execute("drop table nms_recipe_ingredients", at: url)
        let store = try SQLiteNMSStore(fileURL: url)

        XCTAssertThrowsError(try store.recipes(kind: nil, limit: 8, offset: 0))
        XCTAssertThrowsError(
            try store.recipesProducing(type: "product", id: "CIRCUITBOARD")
        )
    }

    func testConversationFailsClosedWhenARequiredRecipeTableIsMissing() async throws {
        let url = try mutablePreviewURL()
        try execute("drop table nms_recipe_ingredients", at: url)
        let settings = AppSettings()
        settings.liveAtlasEnabled = false
        settings.webSearchEnabled = false
        let controller = AtlasSessionController(
            store: try SQLiteNMSStore(fileURL: url),
            settings: settings
        )

        let reply = await controller.reply(to: "Circuit Board recipe")

        XCTAssertEqual(reply.text, "I could not read the installed Atlas pack.")
        XCTAssertTrue(reply.cards.isEmpty)
        XCTAssertTrue(reply.note?.contains("failed closed") == true)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    func testEveryModelDatabaseToolUsesTheInstalledPack() async throws {
        let store = try previewStore()
        let tools = LocalDatabaseToolRegistry.make(store: store)

        XCTAssertEqual(tools.map(\.name), LocalDatabaseToolRegistry.expectedNames)

        let entities = try await SearchEntitiesTool(store: store).call(
            arguments: .init(query: "Ferrite Dust", entityType: nil)
        )
        XCTAssertTrue(entities.contains("FUEL1"))

        let entity = try await GetEntityTool(store: store).call(
            arguments: .init(entityType: "substance", gameId: "FUEL1")
        )
        XCTAssertTrue(entity.contains("Ferrite Dust"))

        let produced = try await RecipesForTool(store: store).call(
            arguments: .init(entityType: "substance", gameId: "FUEL1")
        )
        XCTAssertTrue(produced.contains("refining:substance:FUEL1:0"))

        let consumed = try await RecipesUsingTool(store: store).call(
            arguments: .init(entityType: "substance", gameId: "FUEL1")
        )
        XCTAssertTrue(consumed.contains("crafting:product:CIRCUITBOARD:0"))

        let content = try await SearchContentTool(store: store).call(
            arguments: .init(query: "Pioneers", dataset: nil)
        )
        XCTAssertTrue(content.contains("EXPEDITION_1"))
    }
    #endif

    func testFerriteDustOfflineResponse() async throws {
        let controller = try offlineController()
        let reply = await controller.reply(to: "What is Ferrite Dust for?")

        XCTAssertFalse(reply.text.isEmpty)
        XCTAssertTrue(reply.cards.contains { card in
            guard case .entity(let entity) = card else { return false }
            return entity.title == "Ferrite Dust"
        })
        XCTAssertTrue(reply.cards.contains { card in
            guard case .recipe(let recipe) = card else { return false }
            return recipe.outputGameID == "FUEL1"
                || recipe.ingredients.contains { $0.gameID == "FUEL1" }
        })
    }

    func testCircuitBoardRecipeOfflineResponse() async throws {
        let controller = try offlineController()
        let reply = await controller.reply(to: "Circuit Board recipe")

        XCTAssertFalse(reply.text.isEmpty)
        XCTAssertTrue(reply.cards.contains { card in
            guard case .entity(let entity) = card else { return false }
            return entity.gameID == "CIRCUITBOARD"
        })
        XCTAssertTrue(reply.cards.contains { card in
            guard case .recipe(let recipe) = card else { return false }
            return recipe.recipeKind == "crafting"
                && recipe.outputGameID == "CIRCUITBOARD"
        })
    }

    func testBroadCookingOfflineResponse() async throws {
        let controller = try offlineController()
        let reply = await controller.reply(to: "How do I cook food?")

        XCTAssertFalse(reply.text.isEmpty)
        XCTAssertTrue(reply.cards.contains { card in
            guard case .recipe(let recipe) = card else { return false }
            return recipe.recipeKind == "cooking"
        })
    }

    private func offlineController() throws -> AtlasSessionController {
        let settings = AppSettings()
        settings.liveAtlasEnabled = false
        settings.webSearchEnabled = false
        return AtlasSessionController(store: try previewStore(), settings: settings)
    }

    private func previewStore() throws -> SQLiteNMSStore {
        try SQLiteNMSStore(fileURL: previewURL())
    }

    private func previewURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        guard let url = bundles.lazy.compactMap({
            $0.url(forResource: "nms-reference", withExtension: "sqlite")
        }).first else {
            throw XCTSkip("The host app does not contain the preview SQLite pack.")
        }
        return url
    }

    private func mutablePreviewURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-pack-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let destination = directory.appendingPathComponent("nms-reference.sqlite")
        try FileManager.default.copyItem(at: previewURL(), to: destination)
        return destination
    }

    private func assertManifestRejected(
        after sql: String,
        containing expectedMessage: String
    ) throws {
        let url = try mutablePreviewURL()
        try execute(sql, at: url)
        let store = try SQLiteNMSStore(fileURL: url)
        XCTAssertThrowsError(try store.manifest()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(expectedMessage),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openStatus == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw NSError(
                domain: "AtlasTests.SQLite",
                code: Int(openStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        defer { sqlite3_close(db) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "AtlasTests.SQLite",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

final class PackLifecycleTests: XCTestCase {
    func testProductionCandidateIsCopiedVerifiedAndReopened() async throws {
        let workspace = try temporaryWorkspace()
        let candidate = try productionCandidate(in: workspace, variant: 1)
        let activationRoot = workspace.appendingPathComponent("active")
        let store = PackActivationStore(rootURL: activationRoot)

        let installed = try await store.activate(candidate)
        XCTAssertTrue(installed.sqliteURL.path.contains("/releases/"))
        XCTAssertEqual(installed.sidecar.packRole, "production")
        XCTAssertFalse(installed.recoveredFromRollback)

        try FileManager.default.removeItem(at: candidate.sqliteURL.deletingLastPathComponent())
        let relaunchedStore = PackActivationStore(rootURL: activationRoot)
        let reopenedValue = try await relaunchedStore.current()
        let reopened = try XCTUnwrap(reopenedValue)
        XCTAssertEqual(reopened.sidecar.sqlite.sha256, installed.sidecar.sqlite.sha256)
        XCTAssertNoThrow(try SQLiteNMSStore(fileURL: reopened.sqliteURL).manifest())
    }

    func testRejectedCandidateDoesNotReplaceActiveRelease() async throws {
        let workspace = try temporaryWorkspace()
        let valid = try productionCandidate(in: workspace, variant: 1)
        let store = PackActivationStore(rootURL: workspace.appendingPathComponent("active"))
        let installed = try await store.activate(valid)

        let invalid = try productionCandidate(in: workspace, variant: 2)
        var sidecar = try JSONDecoder().decode(
            PackSidecar.self,
            from: Data(contentsOf: invalid.sidecarURL)
        )
        sidecar = PackSidecar(
            packSchemaVersion: sidecar.packSchemaVersion,
            contractVersion: sidecar.contractVersion,
            assetPackID: sidecar.assetPackID,
            packRole: sidecar.packRole,
            sourceRepository: sidecar.sourceRepository,
            sourceCommitSHA: sidecar.sourceCommitSHA,
            sourceCommittedAt: sidecar.sourceCommittedAt,
            generatedAt: sidecar.generatedAt,
            counts: sidecar.counts,
            sqlite: .init(
                file: sidecar.sqlite.file,
                bytes: sidecar.sqlite.bytes,
                sha256: String(repeating: "0", count: 64)
            ),
            validation: sidecar.validation
        )
        try JSONEncoder().encode(sidecar).write(to: invalid.sidecarURL, options: .atomic)

        do {
            _ = try await store.activate(invalid)
            XCTFail("A candidate with the wrong checksum was activated.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not match"))
        }
        let currentValue = try await store.current()
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.sidecar.sqlite.sha256, installed.sidecar.sqlite.sha256)
    }

    func testCorruptActiveReleaseAutomaticallyRollsBack() async throws {
        let workspace = try temporaryWorkspace()
        let firstCandidate = try productionCandidate(in: workspace, variant: 1)
        let secondCandidate = try productionCandidate(in: workspace, variant: 2)
        let store = PackActivationStore(rootURL: workspace.appendingPathComponent("active"))
        let first = try await store.activate(firstCandidate)
        let second = try await store.activate(secondCandidate)
        XCTAssertNotEqual(first.sidecar.sqlite.sha256, second.sidecar.sqlite.sha256)

        let handle = try FileHandle(forWritingTo: second.sqliteURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let recoveredValue = try await store.current()
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertTrue(recovered.recoveredFromRollback)
        XCTAssertEqual(recovered.sidecar.sqlite.sha256, first.sidecar.sqlite.sha256)

        let stableValue = try await store.current()
        let stable = try XCTUnwrap(stableValue)
        XCTAssertFalse(stable.recoveredFromRollback)
        XCTAssertEqual(stable.sidecar.sqlite.sha256, first.sidecar.sqlite.sha256)
    }

    func testReinstallRepairsACorruptReleaseWithTheSameDigest() async throws {
        let workspace = try temporaryWorkspace()
        let candidate = try productionCandidate(in: workspace, variant: 1)
        let store = PackActivationStore(rootURL: workspace.appendingPathComponent("active"))
        let installed = try await store.activate(candidate)

        let handle = try FileHandle(forWritingTo: installed.sqliteURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let repaired = try await store.activate(candidate)

        XCTAssertEqual(repaired.sidecar.sqlite.sha256, installed.sidecar.sqlite.sha256)
        XCTAssertNoThrow(try SQLiteNMSStore(fileURL: repaired.sqliteURL).manifest())
    }

    func testActivationSucceedsWhenObsoleteReleaseCleanupFails() async throws {
        let workspace = try temporaryWorkspace()
        let activationRoot = workspace.appendingPathComponent("active")
        let staleRelease = activationRoot
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent("stale-release", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staleRelease,
            withIntermediateDirectories: true
        )
        let fileManager = SelectiveFailureFileManager(deniedRemovalURL: staleRelease)
        let store = PackActivationStore(rootURL: activationRoot, fileManager: fileManager)
        let candidate = try productionCandidate(in: workspace, variant: 1)

        let installed = try await store.activate(candidate)

        XCTAssertNoThrow(try SQLiteNMSStore(fileURL: installed.sqliteURL).manifest())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleRelease.path))
    }

    func testValidatorRejectsMalformedOrMismatchedSourceCommitTimestamp() throws {
        let workspace = try temporaryWorkspace()
        let validator = PackValidator(requiredRole: "production")

        let malformed = try productionCandidate(in: workspace, variant: 1)
        try setSidecarSourceCommittedAt("not-a-timestamp", for: malformed)
        XCTAssertThrowsError(try validator.validate(malformed))

        let mismatched = try productionCandidate(in: workspace, variant: 2)
        try setSidecarSourceCommittedAt("2025-01-01T00:00:00Z", for: mismatched)
        XCTAssertThrowsError(try validator.validate(mismatched))
    }

    private func productionCandidate(
        in workspace: URL,
        variant: Int
    ) throws -> PackCandidate {
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        let sourceSQLite = try XCTUnwrap(bundles.lazy.compactMap {
            $0.url(forResource: "nms-reference", withExtension: "sqlite")
        }.first)
        let sourceSidecar = try XCTUnwrap(bundles.lazy.compactMap {
            $0.url(forResource: "pack-manifest", withExtension: "json")
        }.first)
        let directory = workspace.appendingPathComponent("candidate-\(variant)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqliteURL = directory.appendingPathComponent(PackLocator.sqliteName)
        let sidecarURL = directory.appendingPathComponent(PackLocator.sidecarName)
        try FileManager.default.copyItem(at: sourceSQLite, to: sqliteURL)

        let generatedAt = "2026-08-30T12:00:0\(variant)+00:00"
        try execute(
            "update pack_manifest set generated_at = '\(generatedAt)'",
            at: sqliteURL
        )
        let preview = try JSONDecoder().decode(
            PackSidecar.self,
            from: Data(contentsOf: sourceSidecar)
        )
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sqliteURL.path)[.size] as? NSNumber
        ).intValue
        let production = PackSidecar(
            packSchemaVersion: preview.packSchemaVersion,
            contractVersion: preview.contractVersion,
            assetPackID: preview.assetPackID,
            packRole: "production",
            sourceRepository: preview.sourceRepository,
            sourceCommitSHA: preview.sourceCommitSHA,
            sourceCommittedAt: preview.sourceCommittedAt,
            generatedAt: generatedAt,
            counts: preview.counts,
            sqlite: .init(
                file: PackLocator.sqliteName,
                bytes: size,
                sha256: try PackValidator.sha256(sqliteURL)
            ),
            validation: preview.validation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(production).write(to: sidecarURL, options: .atomic)
        return PackCandidate(sqliteURL: sqliteURL, sidecarURL: sidecarURL)
    }

    private func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atlas-lifecycle-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func setSidecarSourceCommittedAt(
        _ value: String,
        for candidate: PackCandidate
    ) throws {
        let data = try Data(contentsOf: candidate.sidecarURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["source_committed_at"] = value
        let updated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updated.write(to: candidate.sidecarURL, options: .atomic)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openStatus == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NSError(domain: "PackLifecycleTests", code: Int(openStatus))
        }
        defer { sqlite3_close(db) }
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw NSError(
                domain: "PackLifecycleTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
    }
}

private final class SelectiveFailureFileManager: FileManager, @unchecked Sendable {
    private let deniedRemovalPath: String

    init(deniedRemovalURL: URL) {
        deniedRemovalPath = deniedRemovalURL.standardizedFileURL.path
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL.path == deniedRemovalPath {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
