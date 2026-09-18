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
        XCTAssertEqual(Int(plan.derivedEvidence.output), 3)
        XCTAssertEqual(plan.derivedEvidence.normalizedInputs["checklistSummary"], "18× Carbon")
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
        XCTAssertEqual(defaultPlan.alternatives.first?.title, "Carbon")
        XCTAssertFalse(defaultPlan.alternatives.first?.recipes.contains(where: { $0.title.isEmpty }) == true)
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
        XCTAssertThrowsError(try Quantity.sum(999_999, 1))
    }

    func testMergedLeafOverflowFailsClosed() async {
        let source = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(
                    id: "craft:A",
                    outputType: "product",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "C", "999999"), ("substance", "C", "1")]
                ),
            ],
            titles: ["product:A": "Circuit Board", "substance:C": "Carbon"]
        )
        do {
            _ = try await RecipeGraphEngine().plan(
                targetType: "product",
                targetID: "A",
                quantity: 1,
                packReleaseID: "pack-1",
                source: source
            )
            XCTFail("Leaf overflow must fail closed")
        } catch let error as ConversationBoundError {
            switch error {
            case .quantityOverflow, .quantityOutOfRange:
                break
            default:
                XCTFail("Expected quantity bound, got \(error)")
            }
        } catch {
            XCTFail("Expected ConversationBoundError, got \(error)")
        }
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
        XCTAssertEqual(RecipePlanIntent.quantity(from: "Give me a plan for 12 Circuit Boards"), 12)
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
            targetTitle: "Circuit Board",
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
        XCTAssertFalse(diff.engineChanged)
        XCTAssertEqual(diff.missingLineIDs, ["leaf:substance:C"])
        XCTAssertEqual(diff.newLineIDs, ["leaf:substance:D"])

        var engineMismatch = saved
        engineMismatch.engineVersion = "0"
        XCTAssertTrue(RecipePlanRecomputeDiff.compare(saved: engineMismatch, computed: sourcePlan).engineChanged)

        XCTAssertFalse(LocalToolName.coreNames.contains("plan_recipe"))
        XCTAssertFalse(LocalToolName.coreNames.contains("compare_recipe_paths"))
        let catalog = FixtureNMSCatalog(
            identity: pack,
            entities: [
                Self.entity(type: "product", id: "A", title: "Circuit Board"),
                Self.entity(type: "substance", id: "C", title: "Carbon"),
                Self.entity(type: "substance", id: "D", title: "Oxygen"),
            ],
            recipes: [
                Self.recipe(
                    id: "craft:A",
                    outputType: "product",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "C", "6")]
                ),
                Self.recipe(
                    id: "refine:A",
                    outputType: "product",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", "D", "4")]
                ),
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
            XCTAssertTrue(summary.contains("18×") || summary.contains("12×"))
        } else {
            XCTFail("plan_recipe must return a typed message payload")
        }

        let compared = try await tools.invoke(
            LocalToolCall(
                name: "compare_recipe_paths",
                query: "refine:A",
                entityType: "product",
                gameID: "A",
                recipeID: "craft:A",
                quantity: 3
            )
        )
        XCTAssertEqual(compared.status, .ok)
        XCTAssertEqual(compared.evidenceIDs.count, 2)
        if case .message(let summary) = compared.payload {
            XCTAssertTrue(summary.contains("18×"))
            XCTAssertTrue(summary.contains("12×"))
            XCTAssertTrue(summary.contains("Carbon"))
            XCTAssertTrue(summary.contains("Oxygen"))
        } else {
            XCTFail("compare_recipe_paths must return a typed message payload")
        }
    }

    func testNeedQuantityPromptDropsIntegerFromLocalSearch() {
        let plan = AtlasQueryPlan(prompt: "I need 12 Circuit Boards")
        XCTAssertEqual(plan.source, .local)
        XCTAssertEqual(plan.localQuery, "Circuit Boards")
        XCTAssertFalse(plan.localQuery?.contains("12") == true)
        XCTAssertEqual(plan.localSearchQueries, ["Circuit Boards", "circuit board"])
        XCTAssertEqual(RecipePlanIntent.quantity(from: plan.originalPrompt), 12)
    }

    func testPlanForQuantityKeepsOnlyTheItemInLocalSearch() {
        let plan = AtlasQueryPlan(prompt: "Give me a plan for 12 Circuit Boards")
        XCTAssertEqual(plan.source, .local)
        XCTAssertEqual(plan.localQuery, "Circuit Boards")
        XCTAssertEqual(plan.localSearchQueries, ["Circuit Boards", "circuit board"])
        XCTAssertEqual(RecipePlanIntent.quantity(from: plan.originalPrompt), 12)
    }

    func testNeedTwelveCircuitBoardsGroundedPlanWhenModelUnavailable() async {
        let catalog = FixtureNMSCatalog(
            identity: Self.pack,
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
                ),
            ],
            records: []
        )
        let engine = AtlasConversationEngine()
        let turn = await engine.reply(
            ConversationTurnRequest(
                prompt: "I need 12 Circuit Boards",
                turnID: "turn-1",
                generation: 1,
                packIdentity: Self.pack,
                catalog: catalog,
                snapshot: SourcePolicySnapshot(
                    liveAtlasCapabilityEnabled: false,
                    webSearchCapabilityEnabled: false,
                    packAvailable: true
                ),
                receipts: [],
                external: .empty,
                flags: .disabled,
                modelAvailability: .unavailable,
                identifiers: UUIDIdentifierSource(),
                clock: FixedClock(date: Date(timeIntervalSince1970: 1_800_000_000))
            ),
            queryPlanner: DeterministicModelPlanner(),
            proposedPlanner: DeterministicTurnPlanner()
        )
        XCTAssertTrue(turn.usedDeterministicFallback)
        XCTAssertTrue(turn.text.contains("Plan for 12× Circuit Board"))
        XCTAssertTrue(turn.text.contains("72× Carbon"))
        XCTAssertTrue(turn.text.contains("\n"))
        XCTAssertTrue(turn.note?.contains("Calculated from pack") == true)
        XCTAssertTrue(turn.cards.contains { card in
            guard case .entity(let entity) = card else { return false }
            return entity.title == "Circuit Board"
        })
        XCTAssertTrue(turn.followUps.contains { chip in
            if case .plan(let type, let id, let quantity) = chip.intent {
                return type == "product" && id == "A" && quantity == 12
            }
            return false
        })
        XCTAssertTrue(turn.followUps.contains { $0.label.contains("12") && $0.label.lowercased().contains("plan") })
        XCTAssertFalse(turn.text.localizedCaseInsensitiveContains("http"))
        XCTAssertFalse(turn.note?.localizedCaseInsensitiveContains("http") == true)
    }

    func testConsecutiveConversationTurnsKeepOnlyTheCurrentAnswer() async throws {
        var catalog = Self.boardCatalog(
            pack: Self.pack,
            ingredientID: "C",
            ingredientTitle: "Carbon",
            amount: "6"
        )
        catalog.entities.append(contentsOf: [
            Self.entity(type: "product", id: "F_DUST_EPIC_L1", title: "Ferrite Bowfin"),
            Self.entity(type: "substance", id: "LAND1", title: "Ferrite Dust"),
        ])
        catalog.records = ["bait", "fish"].enumerated().map { index, dataset in
            ContentRecord(
                dataset: dataset,
                externalID: "F_DUST_EPIC_L1",
                sourceOrdinal: index,
                displayName: "Ferrite Bowfin",
                payload: "{}",
                sourceCommitSHA: Self.pack.sourceCommitSHA
            )
        }

        let plans = await assertConversationTurnsStayFocused(
            catalog: catalog,
            pack: Self.pack,
            boardID: "A"
        )
        XCTAssertTrue(plans.twelve.text.contains("72× Carbon"))
        XCTAssertTrue(plans.twentyFour.text.contains("144× Carbon"))
        XCTAssertFalse(plans.twentyFour.text.contains("72× Carbon"))
    }

    func testEvidenceBundlesPreserveSelectedRelevanceAndExcludeResetRecords() throws {
        let ledger = EvidenceLedger(packIdentity: Self.pack, snapshotID: "ordered-answer")
        let board = ledger.issue(
            payload: .entity(Self.entity(type: "product", id: "A", title: "Circuit Board")),
            source: .packed
        )
        let fish = ledger.issue(
            payload: .entity(Self.entity(type: "product", id: "F_DUST_EPIC_L1", title: "Ferrite Bowfin")),
            source: .packed
        )
        _ = ledger.issue(payload: board.payload, source: .packed)
        XCTAssertEqual(ledger.bundle(turnID: "first").evidenceIDs, [board.evidenceID, fish.evidenceID])

        let rankedIDs = [board.evidenceID, fish.evidenceID].sorted(by: >)
        let selection = ledger.bundle(turnID: "ranked", ids: rankedIDs + rankedIDs)
        XCTAssertEqual(selection.evidenceIDs, rankedIDs)

        ledger.reset(packIdentity: Self.pack)
        XCTAssertTrue(ledger.bundle(turnID: "reset").records.isEmpty)
        XCTAssertTrue(ledger.bundle(turnID: "old-selection", ids: rankedIDs).records.isEmpty)
        XCTAssertThrowsError(try ledger.resolve(board.evidenceID)) { error in
            XCTAssertEqual(error as? EvidenceError, .staleID(board.evidenceID))
        }
        let current = ledger.issue(payload: board.payload, source: .packed)
        XCTAssertEqual(ledger.bundle(turnID: "new").evidenceIDs, [current.evidenceID])
        XCTAssertEqual(
            ledger.bundle(turnID: "mixed", ids: [fish.evidenceID, current.evidenceID, board.evidenceID]).evidenceIDs,
            [current.evidenceID]
        )
    }

    func testFullPackCircuitBoardPlanExcludesPriorFishAndBroadSearchMatches() async throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "nms-reference", withExtension: "sqlite"),
            "Hosted Atlas tests require the full generated app database."
        )
        let catalog = SQLiteNMSCatalog(store: try SQLiteNMSStore(fileURL: url), packRole: nil)
        let pack = try await catalog.packIdentity()
        _ = await assertConversationTurnsStayFocused(
            catalog: catalog,
            pack: pack,
            boardID: "FARMPROD9"
        )
    }

    func testFullPackCraftingRouteGathersFourCropsAndOnlySelectedAlternativeChangesTotals() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "nms-reference", withExtension: "sqlite"))
        let catalog = SQLiteNMSCatalog(store: try SQLiteNMSStore(fileURL: url), packRole: nil)
        let pack = try await catalog.packIdentity()
        let source = catalog.asRecipeGraphSource()
        let engine = RecipeGraphEngine()
        let simple = try await engine.plan(
            targetType: "product", targetID: "FARMPROD9", quantity: 12,
            packReleaseID: pack.sourceCommitSHA, source: source
        )
        let crops = ["PLANT_SNOW": 1200, "PLANT_HOT": 2400, "PLANT_DUST": 1200, "PLANT_LUSH": 2400]
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: simple.checklist.map { ($0.gameID, $0.quantity) }), crops)
        XCTAssertTrue(simple.cycles.isEmpty)
        XCTAssertFalse(simple.truncated)
        XCTAssertEqual(simple.root.selectedRecipeID, "crafting:product:FARMPROD9:0")
        for crop in crops.keys {
            XCTAssertEqual(simple.selections["entity:substance:\(crop)"], RecipeAlternative.gatherID)
        }
        XCTAssertEqual(Set(simple.alternatives.map(\.nodeID)), Set(simple.selections.keys))
        let frost = try XCTUnwrap(simple.alternatives.first { $0.nodeID == "entity:substance:PLANT_SNOW" })
        XCTAssertEqual(frost.quantity, 1200)
        let refining = try XCTUnwrap(frost.recipes.first { $0.recipeID == "refining:substance:PLANT_SNOW:1" })
        XCTAssertTrue(refining.ingredientSummary.contains("Dioxite"))
        XCTAssertTrue(refining.ingredientSummary.contains("Oxygen"))
        XCTAssertFalse(refining.ingredientSummary.contains("COLD1"))

        var choices = simple.selections
        choices["entity:substance:PLANT_SNOW"] = refining.recipeID
        choices["entity:substance:UNUSED"] = "unused-route"
        let alternate = try await engine.plan(
            targetType: "product", targetID: "FARMPROD9", quantity: 12,
            packReleaseID: pack.sourceCommitSHA, source: source, selections: choices
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: alternate.checklist.map { ($0.gameID, $0.quantity) }),
            ["COLD1": 2400, "OXYGEN": 1200, "PLANT_HOT": 2400, "PLANT_DUST": 1200, "PLANT_LUSH": 2400]
        )
        XCTAssertTrue(alternate.cycles.isEmpty)
        XCTAssertNil(alternate.selections["entity:substance:UNUSED"])

        choices = alternate.selections
        choices["entity:substance:PLANT_SNOW"] = RecipeAlternative.gatherID
        let restored = try await engine.plan(
            targetType: "product", targetID: "FARMPROD9", quantity: 12,
            packReleaseID: pack.sourceCommitSHA, source: source, selections: choices
        )
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restored.checklist.map { ($0.gameID, $0.quantity) }), crops)
        XCTAssertFalse(restored.alternatives.contains { ["entity:substance:COLD1", "entity:substance:OXYGEN"].contains($0.nodeID) })
        XCTAssertNil(restored.selections["entity:substance:COLD1"])
        XCTAssertNil(restored.selections["entity:substance:OXYGEN"])
    }

    func testGatheringAnIntermediatePrunesItsOldRouteAndAlternativeRequirements() async throws {
        let source = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(id: "craft:A", outputType: "product", outputID: "A", outputAmount: "1", ingredients: [("product", "B", "2")]),
                Self.recipe(id: "craft:B", outputType: "product", outputID: "B", outputAmount: "1", ingredients: [("substance", "C", "3")]),
                Self.recipe(id: "refine:C", outputType: "substance", outputID: "C", outputAmount: "1", ingredients: [("substance", "D", "9")], kind: "refining"),
            ],
            titles: ["product:A": "Board", "product:B": "Component", "substance:C": "Carbon", "substance:D": "Oxygen"]
        )
        let plan = try await RecipeGraphEngine().plan(
            targetType: "product", targetID: "A", quantity: 3, packReleaseID: "pack", source: source,
            selections: ["entity:product:B": RecipeAlternative.gatherID, "entity:substance:C": "refine:C"]
        )
        XCTAssertEqual(plan.checklist.map(\.title), ["Component"])
        XCTAssertEqual(plan.checklist.map(\.quantity), [6])
        XCTAssertEqual(Set(plan.alternatives.map(\.nodeID)), ["entity:product:A", "entity:product:B"])
        XCTAssertNil(plan.selections["entity:substance:C"])
        XCTAssertFalse(plan.checklist.contains { $0.gameID == "D" })
    }

    func testRefiningLoopsRequireExplicitChoiceAndExposeReadableCycleNames() async throws {
        let source = InMemoryRecipeGraphSource(
            recipes: [
                Self.recipe(id: "craft:A", outputType: "product", outputID: "A", outputAmount: "1", ingredients: [("substance", "B", "2")]),
                Self.recipe(id: "refine:B", outputType: "substance", outputID: "B", outputAmount: "1", ingredients: [("substance", "C", "2")], kind: "refining"),
                Self.recipe(id: "refine:C", outputType: "substance", outputID: "C", outputAmount: "1", ingredients: [("substance", "B", "2")], kind: "refining"),
            ],
            titles: ["product:A": "Circuit Board", "substance:B": "Frost Crystal", "substance:C": "Dioxite"]
        )
        let ordinary = try await RecipeGraphEngine().plan(
            targetType: "product", targetID: "A", quantity: 1, packReleaseID: "pack", source: source
        )
        XCTAssertTrue(ordinary.cycles.isEmpty)
        XCTAssertEqual(ordinary.checklist.map(\.title), ["Frost Crystal"])
        XCTAssertEqual(ordinary.checklist.map(\.quantity), [2])
        let selected = try await RecipeGraphEngine().plan(
            targetType: "product", targetID: "A", quantity: 1, packReleaseID: "pack", source: source,
            selections: ["entity:substance:B": "refine:B", "entity:substance:C": "refine:C"]
        )
        let cycle = try XCTUnwrap(selected.cycles.first)
        XCTAssertEqual(cycle.pathTitles, ["Circuit Board", "Frost Crystal", "Dioxite", "Frost Crystal"])
        XCTAssertTrue(selected.checklist.contains(where: \.isCycle))
    }

    private func assertConversationTurnsStayFocused(
        catalog: any NMSCatalog,
        pack: PackIdentity,
        boardID: String
    ) async -> (twelve: ValidatedAssistantTurn, twentyFour: ValidatedAssistantTurn) {
        let engine = AtlasConversationEngine()
        let fish = await reply("Ferrite Bowfin", generation: 1, engine: engine, catalog: catalog, pack: pack)
        XCTAssertEqual(fish.cards.map(\.id), ["entity:product:F_DUST_EPIC_L1"])

        let twelve = await reply(
            "I need 12 Circuit Boards", generation: 2, engine: engine, catalog: catalog, pack: pack
        )
        assertFocusedPlan(twelve, boardID: boardID, quantity: 12)

        let twentyFour = await reply(
            "Give me a plan for 24 Circuit Boards", generation: 3, engine: engine, catalog: catalog, pack: pack
        )
        assertFocusedPlan(twentyFour, boardID: boardID, quantity: 24)
        XCTAssertFalse(twentyFour.text.contains("Plan for 12×"))

        let unknown = await reply(
            "zzzxqvnonexistent", generation: 4, engine: engine, catalog: catalog, pack: pack
        )
        XCTAssertTrue(unknown.text.contains("do not have a local match"))
        XCTAssertTrue(unknown.cards.isEmpty)
        XCTAssertTrue(unknown.allowedActions.isEmpty)
        XCTAssertTrue(unknown.pendingActions.isEmpty)
        XCTAssertTrue(unknown.followUps.isEmpty)
        XCTAssertFalse(unknown.note?.contains("Calculated from pack") == true)

        let lookup = await reply(
            "Ferrite Dust", generation: 5, engine: engine, catalog: catalog, pack: pack
        )
        XCTAssertEqual(lookup.cards.map(\.id), ["entity:substance:LAND1"])
        XCTAssertTrue(lookup.text.contains("Ferrite Dust"))
        XCTAssertFalse(lookup.text.contains("Plan for"))
        XCTAssertFalse(lookup.text.contains("Circuit Board"))
        XCTAssertFalse(lookup.note?.contains("Calculated from pack") == true)
        XCTAssertTrue(lookup.pendingActions.isEmpty)
        XCTAssertTrue(lookup.allowedActions.allSatisfy { action in
            action.recordKeys.allSatisfy { $0 == .entity(type: "substance", id: "LAND1") }
        })
        XCTAssertFalse(lookup.followUps.contains { chip in
            if case .plan(_, _, let quantity) = chip.intent { return quantity != 1 }
            return false
        })
        return (twelve, twentyFour)
    }

    private func assertFocusedPlan(
        _ turn: ValidatedAssistantTurn,
        boardID: String,
        quantity: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            turn.text.localizedCaseInsensitiveContains("plan for \(quantity)× Circuit Board"),
            turn.text,
            file: file,
            line: line
        )
        XCTAssertFalse(turn.text.contains("Ferrite Bowfin"), file: file, line: line)
        XCTAssertEqual(turn.cards.map(\.id), ["entity:product:\(boardID)"], file: file, line: line)
        XCTAssertEqual(
            turn.followUps.map(\.intent),
            [.plan(type: "product", id: boardID, quantity: quantity)],
            file: file,
            line: line
        )
        XCTAssertTrue(turn.pendingActions.isEmpty, file: file, line: line)
        XCTAssertTrue(turn.allowedActions.allSatisfy { action in
            action.recordKeys.allSatisfy { $0 == .entity(type: "product", id: boardID) }
        }, file: file, line: line)
        XCTAssertFalse(turn.allowedActions.contains { resolved in
            if case .plan(_, _, let proposedQuantity) = resolved.action {
                return proposedQuantity != quantity
            }
            return false
        }, file: file, line: line)
    }

    private func reply(
        _ prompt: String,
        generation: UInt64,
        engine: AtlasConversationEngine,
        catalog: any NMSCatalog,
        pack: PackIdentity
    ) async -> ValidatedAssistantTurn {
        await engine.reply(
            ConversationTurnRequest(
                prompt: prompt,
                turnID: "turn-\(generation)",
                generation: generation,
                packIdentity: pack,
                catalog: catalog,
                snapshot: SourcePolicySnapshot(
                    liveAtlasCapabilityEnabled: false,
                    webSearchCapabilityEnabled: false,
                    packAvailable: true
                ),
                receipts: [],
                external: .empty,
                flags: .enabled,
                modelAvailability: .unavailable,
                identifiers: UUIDIdentifierSource(),
                clock: FixedClock(date: Date(timeIntervalSince1970: 1_800_000_000))
            ),
            queryPlanner: DeterministicModelPlanner(),
            proposedPlanner: DeterministicTurnPlanner()
        )
    }

    @MainActor
    func testRecipePlanModelPersistsProgressAndPackChangeKeepsOriginalRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atlas-plan-model-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "atlas.plan.\(UUID().uuidString)"))
        let saved = SavedStore(
            artifacts: SavedArtifactsStore(directory: root, clock: FixedClock(date: now)),
            defaults: defaults
        )
        await saved.bootstrap()

        let pack1 = PackIdentity(
            sourceCommitSHA: "pack-1",
            packSchemaVersion: 2,
            contractVersion: 1,
            generatedAt: "2026-09-04T00:00:00Z",
            packRole: "preview"
        )
        let pack2 = PackIdentity(
            sourceCommitSHA: "pack-2",
            packSchemaVersion: 2,
            contractVersion: 1,
            generatedAt: "2026-09-04T00:00:00Z",
            packRole: "preview"
        )
        let firstCatalog = Self.boardCatalog(pack: pack1, ingredientID: "C", ingredientTitle: "Carbon", amount: "6")
        let secondCatalog = Self.boardCatalog(pack: pack2, ingredientID: "D", ingredientTitle: "Oxygen", amount: "4")
        let identifiers = CountingIdentifierSource()
        let feature = RecipePlanModel(quantity: 3)

        await feature.load(
            type: "product",
            id: "A",
            catalog: firstCatalog,
            packIdentity: pack1,
            saved: saved
        )
        guard case .loaded(let live) = feature.state else {
            return XCTFail("Expected a live plan")
        }
        XCTAssertEqual(live.checklist.first?.gameID, "C")
        XCTAssertEqual(live.checklist.first?.quantity, 18)

        await feature.save(identifiers: identifiers, clock: FixedClock(date: now), saved: saved)
        let originalID = try XCTUnwrap(feature.artifactID)
        XCTAssertEqual(saved.recipePlans.count, 1)
        XCTAssertEqual(saved.recipePlans.first?.packReleaseID, "pack-1")

        let lineID = try XCTUnwrap(live.checklist.first?.id)
        await feature.toggleProgress(lineID: lineID, clock: FixedClock(date: now), saved: saved)
        XCTAssertEqual(saved.recipePlans.first?.progress[lineID], true)

        let relaunched = RecipePlanModel(quantity: 1, artifactID: originalID)
        await relaunched.load(
            type: "product",
            id: "A",
            catalog: firstCatalog,
            packIdentity: pack1,
            saved: saved
        )
        XCTAssertEqual(relaunched.progress[lineID], true)
        XCTAssertEqual(relaunched.quantity, 3)
        XCTAssertNil(relaunched.recomputeDiff)

        await feature.load(
            type: "product",
            id: "A",
            catalog: secondCatalog,
            packIdentity: pack2,
            saved: saved
        )
        XCTAssertTrue(feature.isFrozen)
        XCTAssertEqual(feature.recomputeDiff?.packChanged, true)
        XCTAssertEqual(feature.recomputePreview?.checklist.first?.gameID, "D")
        if case .loaded(let snapshot) = feature.state {
            XCTAssertEqual(snapshot.checklist.first?.gameID, "C")
            XCTAssertTrue(snapshot.alternatives.isEmpty)
            XCTAssertEqual(snapshot.targetTitle, "Circuit Board")
        } else {
            XCTFail("Frozen load must present the saved snapshot")
        }

        feature.quantity = 99
        await feature.save(identifiers: identifiers, clock: FixedClock(date: now), saved: saved)
        let afterFrozenSave = try XCTUnwrap(saved.recipePlan(id: originalID))
        XCTAssertEqual(afterFrozenSave.quantity, 3)
        XCTAssertEqual(afterFrozenSave.packReleaseID, "pack-1")
        XCTAssertEqual(afterFrozenSave.checklist.first?.gameID, "C")
        XCTAssertEqual(afterFrozenSave.progress[lineID], true)
        XCTAssertEqual(saved.recipePlans.count, 1)

        await feature.confirmRecompute(
            identifiers: identifiers,
            clock: FixedClock(date: now),
            saved: saved
        )
        XCTAssertEqual(saved.recipePlans.count, 2)
        let original = try XCTUnwrap(saved.recipePlan(id: originalID))
        XCTAssertEqual(original.revision, 1)
        XCTAssertEqual(original.packReleaseID, "pack-1")
        XCTAssertEqual(original.quantity, 3)
        let nextID = try XCTUnwrap(feature.artifactID)
        XCTAssertNotEqual(nextID, originalID)
        let next = try XCTUnwrap(saved.recipePlan(id: nextID))
        XCTAssertEqual(next.revision, 2)
        XCTAssertEqual(next.predecessorID, originalID)
        XCTAssertEqual(next.packReleaseID, "pack-2")
        XCTAssertEqual(next.checklist.first?.gameID, "D")
        XCTAssertFalse(feature.isFrozen)
    }

    @MainActor
    func testOlderSavedRefiningRoutesPreviewGatheringDefaultsWithoutOverwritingOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-route-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FixedClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "atlas.route-upgrade.\(UUID().uuidString)"))
        let saved = SavedStore(artifacts: SavedArtifactsStore(directory: directory, clock: clock), defaults: defaults)
        await saved.bootstrap()
        var catalog = Self.boardCatalog(pack: Self.pack, ingredientID: "B", ingredientTitle: "Frost Crystal", amount: "2")
        catalog.entities.append(Self.entity(type: "substance", id: "C", title: "Dioxite"))
        catalog.recipes.append(Self.recipe(
            id: "refine:B", outputType: "substance", outputID: "B", outputAmount: "1",
            ingredients: [("substance", "C", "20")], kind: "refining"
        ))
        let oldPlan = try await RecipeGraphEngine().plan(
            targetType: "product", targetID: "A", quantity: 12, packReleaseID: Self.pack.sourceCommitSHA,
            source: catalog.asRecipeGraphSource(), selections: ["entity:substance:B": "refine:B"]
        )
        var original = SavedRecipePlan.from(
            plan: oldPlan, id: "old-plan", revision: 1, predecessorID: nil, progress: [:], now: clock.now()
        )
        original.engineVersion = "1"
        try await saved.upsertRecipePlan(original)
        let model = RecipePlanModel(quantity: 12, artifactID: original.id)
        await model.load(type: "product", id: "A", catalog: catalog, packIdentity: Self.pack, saved: saved)
        XCTAssertTrue(model.isFrozen)
        XCTAssertEqual(model.recomputeDiff?.engineChanged, true)
        XCTAssertEqual(model.recomputePreview?.checklist.map(\.title), ["Frost Crystal"])
        XCTAssertEqual(model.recomputePreview?.checklist.map(\.quantity), [24])
        guard case .loaded(let frozen) = model.state else { return XCTFail("Expected saved checklist") }
        XCTAssertEqual(frozen.checklist.map(\.title), ["Dioxite"])
        XCTAssertEqual(frozen.checklist.map(\.quantity), [480])
        XCTAssertEqual(saved.recipePlan(id: original.id), original)
        await model.confirmRecompute(identifiers: UUIDIdentifierSource(), clock: clock, saved: saved)
        XCTAssertFalse(model.isFrozen)
        XCTAssertEqual(saved.recipePlans.count, 2)
        XCTAssertEqual(saved.recipePlan(id: original.id), original)
        XCTAssertEqual(model.savedRevision?.engineVersion, ComputedRecipePlan.engineVersion)
        XCTAssertEqual(model.savedRevision?.checklist.map(\.title), ["Frost Crystal"])
        XCTAssertEqual(model.savedRevision?.selections["entity:substance:B"], RecipeAlternative.gatherID)
    }

    func testOldCycleSnapshotsDecodeWithoutDisplayNames() throws {
        let json = Data(#"{"nodeID":"entity:substance:B","path":["entity:product:A","entity:substance:B"]}"#.utf8)
        let cycle = try JSONDecoder().decode(CycleNotice.self, from: json)
        XCTAssertNil(cycle.pathTitles)
        XCTAssertEqual(cycle.path.count, 2)
    }

    private static func boardCatalog(
        pack: PackIdentity,
        ingredientID: String,
        ingredientTitle: String,
        amount: String
    ) -> FixtureNMSCatalog {
        FixtureNMSCatalog(
            identity: pack,
            entities: [
                entity(type: "product", id: "A", title: "Circuit Board"),
                entity(type: "substance", id: ingredientID, title: ingredientTitle),
            ],
            recipes: [
                recipe(
                    id: "craft:A",
                    outputType: "product",
                    outputID: "A",
                    outputAmount: "1",
                    ingredients: [("substance", ingredientID, amount)]
                ),
            ],
            records: []
        )
    }

    private static let pack = PackIdentity(
        sourceCommitSHA: "pack-phase-2",
        packSchemaVersion: 2,
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
        ingredients: [(String, String, String)],
        kind: String = "crafting"
    ) -> Recipe {
        Recipe(
            recipeID: id,
            recipeKind: kind,
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

private final class CountingIdentifierSource: IdentifierSource, @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0

    func makeID() -> String {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        return "n\(next)"
    }
}
