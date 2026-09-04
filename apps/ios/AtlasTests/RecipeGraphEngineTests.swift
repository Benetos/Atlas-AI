import XCTest
@testable import Atlas

final class RecipeGraphEngineTests: XCTestCase {
    func testScaledMultiStepPlanMergesLeafTotals() async throws {
        let source = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(
                    id: "craft:A",
                    outputType: "product",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "B", "2")]
                ),
                Self.recipe(
                    id: "craft:B",
                    outputType: "substance",
                    outputID: "B",
                    outputAmount: "1",
                    ingredients: [("substance", "C", "3")]
                ),
            ],
            titles: [
                "product:A": "Circuit Board",
                "substance:B": "Carbon Nanotubes",
                "substance:C": "Carbon",
            ]
        )
        let plan = try await RecipeGraphEngine().plan(
            targetType: "product",
            targetID: "A",
            quantity: 3,
            packReleaseID: "pack-1",
            source: source
        )
        XCTAssertEqual(plan.root.crafts, 3)
        XCTAssertEqual(plan.checklist.count, 1)
        XCTAssertEqual(plan.checklist[0].gameID, "C")
        XCTAssertEqual(plan.checklist[0].quantity, 18)
        XCTAssertEqual(plan.derivedEvidence.engineName, "recipe-graph")
        XCTAssertTrue(plan.derivedEvidence.provenanceLabel.hasPrefix("Calculated from pack"))
        XCTAssertFalse(plan.planID.isEmpty)
    }

    func testAlternatePathChangesChecklist() async throws {
        let source = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(
                    id: "refine:A:0",
                    outputType: "substance",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "B", "1")]
                ),
                Self.recipe(
                    id: "refine:A:1",
                    outputType: "substance",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "C", "4")]
                ),
            ],
            titles: ["substance:A": "Carbon", "substance:B": "Ferrite", "substance:C": "Oxygen"]
        )
        let defaultPlan = try await RecipeGraphEngine().plan(
            targetType: "substance",
            targetID: "A",
            quantity: 1,
            packReleaseID: "pack-1",
            source: source
        )
        XCTAssertEqual(defaultPlan.alternatives.first?.recipes.count, 2)
        XCTAssertEqual(defaultPlan.checklist.first?.gameID, "B")

        let selected = try await RecipeGraphEngine().plan(
            targetType: "substance",
            targetID: "A",
            quantity: 1,
            packReleaseID: "pack-1",
            source: source,
            selections: ["entity:substance:A": "refine:A:1"]
        )
        XCTAssertEqual(selected.selections["entity:substance:A"], "refine:A:1")
        XCTAssertEqual(selected.checklist.first?.gameID, "C")
        XCTAssertEqual(selected.checklist.first?.quantity, 4)
        XCTAssertNotEqual(defaultPlan.planID, selected.planID)
    }

    func testCyclesDoNotHangAndBecomeExplicitLeaves() async throws {
        let source = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(
                    id: "loop:A",
                    outputType: "substance",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "B", "1")]
                ),
                Self.recipe(
                    id: "loop:B",
                    outputType: "substance",
                    outputID: "B",
                    outputAmount: "1",
                    ingredients: [("substance", "A", "1")]
                ),
            ],
            titles: ["substance:A": "A", "substance:B": "B"]
        )
        let plan = try await RecipeGraphEngine().plan(
            targetType: "substance",
            targetID: "A",
            quantity: 1,
            packReleaseID: "pack-1",
            source: source
        )
        XCTAssertFalse(plan.cycles.isEmpty)
        XCTAssertTrue(plan.checklist.contains(where: \.isCycle))
        XCTAssertEqual(plan.root.kind, .crafted)
    }

    func testMissingProducerIsALeafAndUnknownSelectionIsExplicit() async throws {
        let source = InMemoryRecipeGraphSource(
            recipes: [],
            titles: ["substance:LAND1": "Ferrite Dust"]
        )
        let leaf = try await RecipeGraphEngine().plan(
            targetType: "substance",
            targetID: "LAND1",
            quantity: 5,
            packReleaseID: "pack-1",
            source: source
        )
        XCTAssertEqual(leaf.root.kind, .leaf)
        XCTAssertEqual(leaf.checklist.first?.quantity, 5)

        let withRecipe = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(
                    id: "refine:A:0",
                    outputType: "substance",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "B", "1")]
                ),
            ],
            titles: ["substance:A": "A", "substance:B": "B"]
        )
        let missing = try await RecipeGraphEngine().plan(
            targetType: "substance",
            targetID: "A",
            quantity: 1,
            packReleaseID: "pack-1",
            source: withRecipe,
            selections: ["entity:substance:A": "gone"]
        )
        XCTAssertEqual(missing.root.kind, .missingRecipe)
        XCTAssertTrue(missing.notices.contains(where: { $0.contains("not in this snapshot") }))
    }

    func testDepthAndNodeBoundsStopExpansion() async throws {
        var recipes: [Recipe] = []
        var titles: [String: String] = [:]
        for index in 0..<6 {
            let current = "N\(index)"
            let next = "N\(index + 1)"
            titles["substance:\(current)"] = current
            recipes.append(
                Self.recipe(
                    id: "chain:\(current)",
                    outputType: "substance",
                    outputID: current,
                    outputAmount: "1",
                    ingredients: [("substance", next, "1")]
                )
            )
        }
        titles["substance:N6"] = "N6"
        let source = InMemoryRecipeGraphSource(recipes: recipes, titles: titles)
        let shallow = RecipeExpansionBounds(
            depth: 2,
            alternativesPerNode: 5,
            maxVisitedNodes: 500,
            budgetMilliseconds: 750
        )
        let plan = try await RecipeGraphEngine(bounds: shallow).plan(
            targetType: "substance",
            targetID: "N0",
            quantity: 1,
            packReleaseID: "pack-1",
            source: source
        )
        XCTAssertTrue(plan.truncated)
        XCTAssertTrue(plan.checklist.contains(where: \.isTruncated))

        let tiny = RecipeExpansionBounds(
            depth: 12,
            alternativesPerNode: 5,
            maxVisitedNodes: 1,
            budgetMilliseconds: 750
        )
        do {
            _ = try await RecipeGraphEngine(bounds: tiny).plan(
                targetType: "substance",
                targetID: "N0",
                quantity: 1,
                packReleaseID: "pack-1",
                source: source
            )
            XCTFail("Node bound must fail closed")
        } catch let error as ConversationBoundError {
            guard case .recipeExpansionExceeded = error else {
                return XCTFail("Expected expansion bound, got \(error)")
            }
        }
    }

    func testAlternativeCapIsFiveAndOutputScalingUsesCeiling() async throws {
        var recipes: [Recipe] = []
        for index in 0..<7 {
            recipes.append(
                Self.recipe(
                    id: "alt:\(index)",
                    outputType: "product",
                    outputID: "BOARD",
                    outputAmount: "2",
                    ingredients: [("substance", "C\(index)", "1")]
                )
            )
        }
        let source = InMemoryRecipeGraphSource(
            recipes: recipes,
            titles: ["product:BOARD": "Circuit Board"]
        )
        let plan = try await RecipeGraphEngine().plan(
            targetType: "product",
            targetID: "BOARD",
            quantity: 3,
            packReleaseID: "pack-1",
            source: source
        )
        XCTAssertEqual(plan.alternatives.first?.recipes.count, 5)
        XCTAssertEqual(plan.root.crafts, 2)
        XCTAssertEqual(plan.checklist.first?.quantity, 2)
    }

    func testCancellationStopsExpansion() async {
        let source = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(
                    id: "slow",
                    outputType: "product",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "B", "1")]
                ),
            ],
            titles: ["product:A": "A"],
            delayNanoseconds: 400_000_000
        )
        let task = Task {
            try await RecipeGraphEngine().plan(
                targetType: "product",
                targetID: "A",
                quantity: 1,
                packReleaseID: "pack-1",
                source: source
            )
        }
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled planning must not return a plan")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTAssertTrue(error is CancellationError || error is RecipeGraphError)
        }
    }

    func testQuantityOverflowFailsClosed() {
        XCTAssertEqual(try RecipeGraphEngine.craftsNeeded(quantity: 999_999, outputPerCraft: 1), 999_999)
        XCTAssertEqual(try RecipeGraphEngine.craftsNeeded(quantity: 5, outputPerCraft: 2), 3)
        XCTAssertThrowsError(try Quantity.product(999_999, 2))
    }

    func testProgressTransfersOnlyExactLineIdentities() {
        let old = [
            "leaf:substance:C": true,
            "leaf:substance:GONE": true,
        ]
        let checklist = [
            ChecklistLine(
                entityType: "substance",
                gameID: "C",
                title: "Carbon",
                quantity: 4,
                isCycle: false,
                isTruncated: false
            ),
            ChecklistLine(
                entityType: "substance",
                gameID: "D",
                title: "Di-hydrogen",
                quantity: 1,
                isCycle: false,
                isTruncated: false
            ),
        ]
        let transferred = SavedRecipePlan.transferredProgress(from: old, onto: checklist)
        XCTAssertEqual(transferred["leaf:substance:C"], true)
        XCTAssertNil(transferred["leaf:substance:GONE"])
        XCTAssertNil(transferred["leaf:substance:D"])
    }

    func testRecipePlanIntentReadsNeedQuantity() {
        XCTAssertEqual(RecipePlanIntent.quantity(from: "I need 12 Circuit Boards"), 12)
        XCTAssertNil(RecipePlanIntent.quantity(from: "Circuit Board recipe"))
        XCTAssertNil(RecipePlanIntent.quantity(from: "I need 0 boards"))
    }

    func testRecipePlanDestinationRoundTrips() throws {
        let destination = AppDestination.recipePlan(
            type: "product",
            id: "FARMPROD9",
            quantity: 12,
            artifactID: "recipePlan:abc"
        )
        let encoded = try JSONEncoder().encode(destination)
        let decoded = try JSONDecoder().decode(AppDestination.self, from: encoded)
        XCTAssertEqual(decoded, destination)

        let unsaved = AppDestination.recipePlan(type: "product", id: "FARMPROD9", quantity: 3)
        let unsavedRoundTrip = try JSONDecoder().decode(
            AppDestination.self,
            from: try JSONEncoder().encode(unsaved)
        )
        XCTAssertEqual(unsavedRoundTrip, unsaved)
    }

    func testPlanActionIsImmediateAndResolvesTrustedEntity() throws {
        XCTAssertFalse(AtlasAction.plan(type: "substance", id: "LAND1", quantity: 12).requiresConfirmation)
        XCTAssertFalse(AtlasAction.plan(type: "substance", id: "LAND1", quantity: 12).isWrite)

        let pack = Self.pack
        let ledger = EvidenceLedger(packIdentity: pack)
        _ = ledger.issue(payload: .entity(Self.entity(type: "substance", id: "LAND1", title: "Ferrite Dust")), source: .packed)
        let resolved = try ActionResolver().resolve(
            proposal: .plan(type: "substance", id: "LAND1", quantity: 12),
            ledger: ledger,
            packReleaseID: pack.sourceCommitSHA,
            queryPlan: AtlasQueryPlan(prompt: "I need 12 Ferrite Dust"),
            capabilityBundleID: "core"
        )
        XCTAssertEqual(resolved.action, .plan(type: "substance", id: "LAND1", quantity: 12))
        XCTAssertEqual(ActionPolicy().decide(resolved), .allow)
    }

    func testNeedQuantityPromptEmitsPlanFollowUp() {
        let pack = Self.pack
        let ledger = EvidenceLedger(packIdentity: pack)
        _ = ledger.issue(payload: .entity(Self.entity(type: "product", id: "BOARD", title: "Circuit Board")), source: .packed)
        let proposed = DeterministicTurnPlanner.plan(
            prompt: "I need 12 Circuit Boards",
            queryPlan: AtlasQueryPlan(prompt: "I need 12 Circuit Boards"),
            bundle: ledger.bundle(turnID: "turn-1")
        )
        XCTAssertTrue(proposed.followUps.contains { intent in
            if case .plan(let type, let id, let quantity) = intent {
                return type == "product" && id == "BOARD" && quantity == 12
            }
            return false
        })
        XCTAssertTrue(proposed.actions.contains { $0.kind == "plan" && $0.payload["quantity"] == "12" })
    }

    func testSavedRecipePlanRoundTripKeepsProgressAndNewRevisionLeavesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atlas-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SavedArtifactsStore(directory: root, clock: FixedClock(date: now))
        let checklist = [
            ChecklistLine(
                entityType: "substance",
                gameID: "C",
                title: "Carbon",
                quantity: 18,
                isCycle: false,
                isTruncated: false
            )
        ]
        let original = SavedRecipePlan(
            id: "recipePlan:1",
            revision: 1,
            predecessorID: nil,
            title: "3× Circuit Board",
            targetType: "product",
            targetID: "A",
            quantity: 3,
            selections: ["entity:product:A": "craft:A"],
            checklist: checklist,
            notices: [],
            cycles: [],
            truncated: false,
            progress: ["leaf:substance:C": true],
            engineVersion: "1",
            bounds: .current,
            packReleaseID: "pack-1",
            planID: "plan-digest-1",
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.upsertRecipePlan(original)
        let snapshot = try await store.snapshot()
        let loaded = try XCTUnwrap(snapshot.recipePlans.first)
        XCTAssertEqual(loaded.checklist, checklist)
        XCTAssertEqual(loaded.progress["leaf:substance:C"], true)
        XCTAssertEqual(loaded.packReleaseID, "pack-1")
        XCTAssertEqual(loaded.selections["entity:product:A"], "craft:A")

        var next = original
        next.id = "recipePlan:2"
        next.revision = 2
        next.predecessorID = original.id
        next.packReleaseID = "pack-2"
        next.planID = "plan-digest-2"
        next.progress = SavedRecipePlan.transferredProgress(
            from: original.progress,
            onto: [
                ChecklistLine(
                    entityType: "substance",
                    gameID: "D",
                    title: "Di-hydrogen",
                    quantity: 4,
                    isCycle: false,
                    isTruncated: false
                )
            ]
        )
        _ = try await store.upsertRecipePlan(next)
        let after = try await store.snapshot()
        XCTAssertEqual(after.recipePlans.count, 2)
        XCTAssertTrue(after.recipePlans.contains { $0.id == "recipePlan:1" && $0.revision == 1 && $0.packReleaseID == "pack-1" })
        XCTAssertTrue(after.recipePlans.contains { $0.id == "recipePlan:2" && $0.revision == 2 && $0.predecessorID == "recipePlan:1" })
        XCTAssertTrue(after.recipePlans.first { $0.id == "recipePlan:2" }?.progress.isEmpty == true)
    }

    func testRecomputeDiffAndPlanRecipeToolStayOffTheCoreNine() async throws {
        let pack = Self.pack
        let sourcePlan = try await RecipeGraphEngine().plan(
            targetType: "product",
            targetID: "A",
            quantity: 3,
            packReleaseID: "pack-1",
            source: InMemoryRecipeGraphSource(
                recipes: [
                    Self.recipe(
                        id: "craft:A",
                        outputType: "product",
                        outputID: "A",
                        outputAmount: "1",
                        ingredients: [("substance", "C", "6")]
                    )
                ],
                titles: ["product:A": "Circuit Board", "substance:C": "Carbon"]
            )
        )
        let saved = SavedRecipePlan.from(
            plan: sourcePlan,
            id: "recipePlan:1",
            revision: 1,
            predecessorID: nil,
            progress: ["leaf:substance:C": true],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var stale = sourcePlan
        stale.packReleaseID = "pack-2"
        stale.checklist = [
            ChecklistLine(
                entityType: "substance",
                gameID: "D",
                title: "Oxygen",
                quantity: 4,
                isCycle: false,
                isTruncated: false
            )
        ]
        let diff = RecipePlanRecomputeDiff.compare(saved: saved, computed: stale)
        XCTAssertTrue(diff.packChanged)
        XCTAssertEqual(diff.missingLineIDs, ["leaf:substance:C"])
        XCTAssertEqual(diff.newLineIDs, ["leaf:substance:D"])

        XCTAssertFalse(LocalToolName.coreNames.contains("plan_recipe"))
        let catalog = FixtureNMSCatalog(
            identity: pack,
            entities: [
                Self.entity(type: "product", id: "A", title: "Circuit Board"),
                Self.entity(type: "substance", id: "C", title: "Carbon"),
            ],
            recipes: [
                Self.recipe(
                    id: "craft:A",
                    outputType: "product",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "C", "6")]
                )
            ],
            records: []
        )
        let ledger = EvidenceLedger(packIdentity: pack)
        let tools = LocalKnowledgeToolRegistry(
            database: LocalDatabaseToolRegistry(catalog: catalog, ledger: ledger, packIdentity: pack)
        )
        let output = try await tools.invoke(
            LocalToolCall(name: "plan_recipe", entityType: "product", gameID: "A", quantity: 3)
        )
        XCTAssertEqual(output.status, .ok)
        XCTAssertFalse(output.evidenceIDs.isEmpty)
        if case .message(let summary) = output.payload {
            XCTAssertTrue(summary.contains("18×"))
        } else {
            XCTFail("plan_recipe must return a typed message payload")
        }
    }

    private static let pack = PackIdentity(
        sourceCommitSHA: "pack-phase-2",
        packSchemaVersion: 1,
        contractVersion: 1,
        generatedAt: "2026-09-04T00:00:00Z",
        packRole: "preview"
    )

    private static func entity(type: String, id: String, title: String) -> Entity {
        Entity(
            entityType: type,
            gameID: id,
            name: title,
            displayName: title,
            subtitle: nil,
            description: "\(title) is packed.",
            category: nil,
            subcategory: nil,
            rarity: nil,
            legality: nil,
            baseValue: nil,
            colorR: nil,
            colorG: nil,
            colorB: nil,
            sourceDataset: "PRODUCT",
            sourceCommitSHA: pack.sourceCommitSHA
        )
    }

    private static func recipe(
        id: String,
        outputType: String,
        outputID: String,
        outputAmount: String,
        ingredients: [(String, String, String)]
    ) -> Recipe {
        Recipe(
            recipeID: id,
            recipeKind: "crafting",
            outputEntityType: outputType,
            outputGameID: outputID,
            outputAmount: outputAmount,
            timeSeconds: nil,
            recipeType: nil,
            recipeName: id,
            sourceOrdinal: 0,
            sourceCommitSHA: "pack-1",
            ingredients: ingredients.enumerated().map { index, part in
                RecipeIngredient(
                    recipeID: id,
                    position: index,
                    entityType: part.0,
                    gameID: part.1,
                    amount: part.2,
                    title: part.1
                )
            },
            outputTitle: outputID
        )
    }
}
