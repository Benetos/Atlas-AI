import CryptoKit
import XCTest
@testable import Atlas

@MainActor
final class AtlasRouterTests: XCTestCase {
    func testCrossSectionOpenRetainsTheSourceBackStack() {
        let router = AtlasRouter()
        router.open(.entity(type: "substance", id: "LAND1"), in: .atlas)
        router.open(.recipe(id: "refining:substance:LAND1:0"), in: .atlas)

        router.open(.entity(type: "product", id: "FARMPROD9"), in: .library)

        XCTAssertEqual(router.selectedSection, .library)
        XCTAssertEqual(
            router.atlasPath,
            [
                .entity(type: "substance", id: "LAND1"),
                .recipe(id: "refining:substance:LAND1:0"),
            ]
        )
        XCTAssertEqual(router.libraryPath, [.entity(type: "product", id: "FARMPROD9")])
        XCTAssertTrue(router.savedPath.isEmpty)
    }

    func testSelectReplacesTheSectionPathAndOpenAppendsFromDetail() {
        let router = AtlasRouter()
        router.select(.entity(type: "substance", id: "LAND1"), in: .library)
        router.select(.entity(type: "product", id: "FARMPROD9"), in: .library)
        XCTAssertEqual(router.libraryPath, [.entity(type: "product", id: "FARMPROD9")])

        router.open(.recipe(id: "recipe-1"), in: .library)
        XCTAssertEqual(
            router.libraryPath,
            [
                .entity(type: "product", id: "FARMPROD9"),
                .recipe(id: "recipe-1"),
            ]
        )
        router.open(.recipe(id: "recipe-1"), in: .library)
        XCTAssertEqual(router.libraryPath.count, 2)
    }

    func testRegularDetailProjectionKeepsTheRootAndPushedRest() {
        XCTAssertNil(AtlasRouter.regularDetail(from: []))
        let path: [AppDestination] = [
            .entity(type: "substance", id: "LAND1"),
            .recipe(id: "recipe-1"),
        ]
        let projected = AtlasRouter.regularDetail(from: path)
        XCTAssertEqual(projected?.root, .entity(type: "substance", id: "LAND1"))
        XCTAssertEqual(projected?.rest, [.recipe(id: "recipe-1")])
    }

    func testPopAndPathBindingShareTheSameSectionState() {
        let router = AtlasRouter()
        router.open(.entity(type: "substance", id: "LAND1"), in: .atlas)
        router.open(.recipe(id: "recipe-1"), in: .atlas)

        router.pathBinding(.atlas).wrappedValue.append(.entity(type: "substance", id: "LAND2"))
        XCTAssertEqual(router.atlasPath.count, 3)

        router.pop(in: .atlas)
        XCTAssertEqual(router.atlasPath, [
            .entity(type: "substance", id: "LAND1"),
            .recipe(id: "recipe-1"),
        ])
        router.pop(in: .atlas)
        router.pop(in: .atlas)
        router.pop(in: .atlas)
        XCTAssertTrue(router.atlasPath.isEmpty)
    }

    func testDestinationEnvelopeRejectsUnknownSchemaVersions() throws {
        let payload = """
        {"schemaVersion":2,"kind":"entity","entityType":"substance","id":"LAND1"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppDestination.self, from: payload)
        guard case .unavailable(let unavailable) = decoded else {
            return XCTFail("Unknown route versions must decode as unavailable.")
        }
        XCTAssertEqual(unavailable.reason, .capabilityUnavailable)

        let encoded = try JSONEncoder().encode(AppDestination.recipe(id: "recipe-1"))
        let roundTrip = try JSONDecoder().decode(AppDestination.self, from: encoded)
        XCTAssertEqual(roundTrip, .recipe(id: "recipe-1"))
    }
}

@MainActor
final class CatalogAndLoadStateTests: XCTestCase {
    func testNotFoundIsDistinctFromFailure() async {
        let catalog = FixtureNMSCatalog(
            identity: .fixture,
            entities: [Entity.fixtureFerrite],
            recipes: [Recipe.fixtureCarbon],
            records: []
        )
        let model = EntityDetailModel()

        await model.load(
            type: "substance",
            id: "MISSING",
            catalog: catalog,
            packIdentity: .fixture
        )
        guard case .notFound = model.state else {
            return XCTFail("Missing records must use notFound, got \(String(describing: model.state))")
        }

        let failing = FixtureNMSCatalog(
            identity: .fixture,
            entities: [Entity.fixtureFerrite],
            recipes: [],
            records: [],
            forcedError: .failure("disk I/O failed")
        )
        await model.load(
            type: "substance",
            id: "LAND1",
            catalog: failing,
            packIdentity: .fixture
        )
        guard case .failed(let message) = model.state else {
            return XCTFail("Store failures must stay distinct from notFound.")
        }
        XCTAssertEqual(message, "disk I/O failed")
    }

    func testLoadedEntityCarriesPackedProvenance() async {
        let catalog = FixtureNMSCatalog(
            identity: .fixture,
            entities: [Entity.fixtureFerrite],
            recipes: [Recipe.fixtureCarbon],
            records: []
        )
        let model = EntityDetailModel()
        await model.load(
            type: "substance",
            id: "LAND1",
            catalog: catalog,
            packIdentity: .fixture
        )
        guard case .loaded(let content) = model.state else {
            return XCTFail("Expected a loaded entity.")
        }
        XCTAssertEqual(content.entity.gameID, "LAND1")
        XCTAssertEqual(content.usedIn.map(\.recipeID), ["refining:substance:LAND1:0"])
        XCTAssertEqual(content.provenance.kind, .packed)
        XCTAssertEqual(content.provenance.releaseLabel, String("142d9ffd8078944722243398202f22cbef47cd02".prefix(12)))
    }

    func testSQLiteCatalogMapsNilToNotFoundAndDoesNotUseNetwork() async throws {
        let url = try XCTUnwrap(
            Bundle(for: CatalogAndLoadStateTests.self).url(forResource: "nms-reference", withExtension: "sqlite")
        )
        let catalog = SQLiteNMSCatalog(
            store: try SQLiteNMSStore(fileURL: url),
            packRole: "preview"
        )
        do {
            _ = try await catalog.entity(type: "substance", id: "does-not-exist")
            XCTFail("Missing entities must throw.")
        } catch let error as CatalogError {
            XCTAssertEqual(error, .notFound(.entity(type: "substance", id: "does-not-exist")))
        }

        let identity = try await catalog.packIdentity()
        XCTAssertEqual(identity.packSchemaVersion, 1)
        XCTAssertFalse(identity.sourceCommitSHA.isEmpty)
    }

    func testInjectedFixtureCatalogSavesAndRelaunchesWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atlas-appmodel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "atlas.appmodel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let catalog = FixtureNMSCatalog(
            identity: .fixture,
            entities: [.fixtureFerrite],
            recipes: [.fixtureCarbon],
            records: []
        )
        let services = AppServices.isolated(
            root: root,
            defaults: defaults,
            catalog: catalog,
            packIdentity: .fixture
        )
        let model = AppModel(services: services)
        await model.saved.bootstrap()
        XCTAssertEqual(model.packStatus, .ready)
        XCTAssertEqual(model.services.network.requestCount, 0)

        let detail = EntityDetailModel()
        await detail.load(
            type: "substance",
            id: "LAND1",
            catalog: try XCTUnwrap(model.catalog),
            packIdentity: model.packIdentity
        )
        guard case .loaded(let content) = detail.state else {
            return XCTFail("Fixture catalog should load Ferrite Dust.")
        }
        XCTAssertEqual(content.usedIn.map(\.recipeID), ["refining:substance:LAND1:0"])
        await model.saved.toggle(model.bookmark(for: content.entity))
        XCTAssertNil(model.saved.lastError)
        XCTAssertTrue(model.saved.isSaved(model.bookmark(for: content.entity)))

        await model.refreshLiveRevision()
        XCTAssertEqual(model.services.network.requestCount, 0)

        let relaunched = SavedStore(
            artifacts: SavedArtifactsStore(directory: services.savedDirectory, clock: services.clock),
            defaults: defaults
        )
        await relaunched.bootstrap()
        XCTAssertEqual(relaunched.items.map(\.id), ["entity:substance:LAND1"])
        XCTAssertEqual(relaunched.items.first?.title, "Ferrite Dust")
    }
}

final class SavedArtifactsStoreTests: XCTestCase {
    func testCorruptFileRecoversThePreviousCopy() async throws {
        let root = try temporaryRoot()
        let clock = FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let store = SavedArtifactsStore(directory: root, clock: clock)
        let ferrite = SavedItem.entity(
            .fixtureFerrite,
            savedAt: clock.now(),
            packReleaseID: PackIdentity.fixture.sourceCommitSHA
        )

        _ = try await store.upsertBookmark(ferrite)
        _ = try await store.rememberRecent(ferrite)

        let current = root.appendingPathComponent("saved-artifacts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))

        try Data("{\"truncated".utf8).write(to: current, options: .atomic)

        let recovered = try await store.snapshot()
        XCTAssertEqual(recovered.bookmarks.map(\.id), [ferrite.id])
        XCTAssertEqual(recovered.bookmarks.first?.title, "Ferrite Dust")
        XCTAssertEqual(
            recovered.bookmarks.first?.originatingPackReleaseID,
            PackIdentity.fixture.sourceCommitSHA
        )

        let quarantine = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("quarantine"),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(quarantine.isEmpty)
    }

    func testLegacyBookmarkMigrationIsIdempotentAndLeavesTheOldKey() async throws {
        let root = try temporaryRoot()
        let suite = "atlas.saved.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let savedAt = Date(timeIntervalSince1970: 1_700_000_100)
        struct LegacySavedItem: Codable {
            var kind: String
            var entityType: String?
            var gameID: String?
            var recipeID: String?
            var title: String
            var savedAt: Date
        }
        let legacy = [
            LegacySavedItem(
                kind: "entity",
                entityType: "substance",
                gameID: "LAND1",
                recipeID: nil,
                title: "Ferrite Dust",
                savedAt: savedAt
            ),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: SavedArtifactsStore.bookmarksDefaultsKey)

        let store = SavedArtifactsStore(
            directory: root,
            clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_200))
        )
        let first = try await store.migrateLegacyBookmarksIfNeeded(defaults: defaults)
        let second = try await store.migrateLegacyBookmarksIfNeeded(defaults: defaults)

        XCTAssertEqual(first.bookmarks.map(\.id), ["entity:substance:LAND1"])
        XCTAssertEqual(second.bookmarks.map(\.id), ["entity:substance:LAND1"])
        XCTAssertEqual(first.bookmarks.count, second.bookmarks.count)
        XCTAssertNotNil(defaults.data(forKey: SavedArtifactsStore.bookmarksDefaultsKey))
    }

    func testCorruptFileWithoutPreviousCopyStartsEmptyAndQuarantines() async throws {
        let root = try temporaryRoot()
        let store = SavedArtifactsStore(
            directory: root,
            clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_400))
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("saved-artifacts.json")
        try Data("not-json".utf8).write(to: current, options: .atomic)

        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.bookmarks.isEmpty)
        let quarantine = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("quarantine"),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(quarantine.isEmpty)
    }

    func testInvalidLegacyJSONDoesNotCompleteMigration() async throws {
        let root = try temporaryRoot()
        let suite = "atlas.saved.invalid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"not\":\"an array\"}".utf8), forKey: SavedArtifactsStore.bookmarksDefaultsKey)

        let store = SavedArtifactsStore(
            directory: root,
            clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_500))
        )
        let first = try await store.migrateLegacyBookmarksIfNeeded(defaults: defaults)
        XCTAssertTrue(first.bookmarks.isEmpty)

        let current = root.appendingPathComponent("saved-artifacts.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))

        struct LegacySavedItem: Codable {
            var kind: String
            var entityType: String?
            var gameID: String?
            var recipeID: String?
            var title: String
            var savedAt: Date
        }
        defaults.set(
            try JSONEncoder().encode([
                LegacySavedItem(
                    kind: "entity",
                    entityType: "substance",
                    gameID: "LAND1",
                    recipeID: nil,
                    title: "Ferrite Dust",
                    savedAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
            ]),
            forKey: SavedArtifactsStore.bookmarksDefaultsKey
        )
        let second = try await store.migrateLegacyBookmarksIfNeeded(defaults: defaults)
        XCTAssertEqual(second.bookmarks.map(\.id), ["entity:substance:LAND1"])
    }

    func testUnknownArtifactKindsSurviveRoundTrip() async throws {
        let root = try temporaryRoot()
        let store = SavedArtifactsStore(
            directory: root,
            clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_300))
        )
        _ = try await store.upsertBookmark(
            SavedItem.entity(.fixtureFerrite, savedAt: Date(), packReleaseID: "abc")
        )

        let current = root.appendingPathComponent("saved-artifacts.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: current)) as? [String: Any]
        )
        var bookmarks = try XCTUnwrap(object["bookmarks"] as? [[String: Any]])
        bookmarks.append([
            "id": "plan:future",
            "kind": "recipePlan",
            "payloadVersion": 1,
            "createdAt": iso8601(Date(timeIntervalSince1970: 1_700_000_300)),
            "updatedAt": iso8601(Date(timeIntervalSince1970: 1_700_000_300)),
            "originatingCapabilities": ["recipes"],
            "payload": ["title": "Circuit Board", "quantity": 12],
        ])
        object["bookmarks"] = bookmarks
        object.removeValue(forKey: "checksum")
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        object["checksum"] = sha256(canonical)
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: current, options: .atomic)

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.bookmarks.count, 1)
        XCTAssertTrue(snapshot.records.contains { $0.kind == "recipePlan" && $0.id == "plan:future" })

        _ = try await store.upsertBookmark(
            SavedItem.recipe(.fixtureCarbon, savedAt: Date(), packReleaseID: "abc")
        )
        let after = try await store.snapshot()
        XCTAssertTrue(after.records.contains { $0.kind == "recipePlan" })
        XCTAssertEqual(after.bookmarks.count, 2)
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atlas-saved-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension PackIdentity {
    static let fixture = PackIdentity(
        sourceCommitSHA: "142d9ffd8078944722243398202f22cbef47cd02",
        packSchemaVersion: 1,
        contractVersion: 1,
        generatedAt: "2026-08-31T04:30:33Z",
        packRole: "preview"
    )
}

private extension Entity {
    static let fixtureFerrite = Entity(
        entityType: "substance",
        gameID: "LAND1",
        name: "Ferrite Dust",
        displayName: "Ferrite Dust",
        subtitle: "Silicate powder",
        description: "A common metallic substance.",
        category: nil,
        subcategory: nil,
        rarity: nil,
        legality: nil,
        baseValue: nil,
        colorR: nil,
        colorG: nil,
        colorB: nil,
        sourceDataset: "SUBSTANCE",
        sourceCommitSHA: PackIdentity.fixture.sourceCommitSHA
    )
}

private extension Recipe {
    static let fixtureCarbon = Recipe(
        recipeID: "refining:substance:LAND1:0",
        recipeKind: "refining",
        outputEntityType: "substance",
        outputGameID: "FUEL1",
        outputAmount: "1",
        timeSeconds: nil,
        recipeType: nil,
        recipeName: nil,
        sourceOrdinal: 0,
        sourceCommitSHA: PackIdentity.fixture.sourceCommitSHA,
        ingredients: [
            RecipeIngredient(
                recipeID: "refining:substance:LAND1:0",
                position: 0,
                entityType: "substance",
                gameID: "LAND1",
                amount: "1",
                title: "Ferrite Dust"
            ),
        ],
        outputTitle: "Carbon"
    )
}
