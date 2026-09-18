import XCTest
@testable import Atlas

final class FeatureHandoffTests: XCTestCase {
    private let clock = FixedClock(date: Date(timeIntervalSince1970: 1_800_000_000))

    func testNightFrozenPromptOpensFishTimeAndBiome() throws {
        let plan = AtlasQueryPlan(prompt: "What can I catch at night on a frozen planet?")
        let route = try XCTUnwrap(plan.specialistRoute)

        XCTAssertEqual(plan.goal, .browseSpecialist)
        XCTAssertEqual(route.feature, .fish)
        XCTAssertEqual(route.timeOfDay, "Night")
        XCTAssertEqual(route.biome, "Frozen")
        XCTAssertEqual(route.destination, .specialist(route))
        XCTAssertNotEqual(route.destination, .content(dataset: "fish", id: "F_JELLYCHILD", sourceOrdinal: 0))
    }

    func testFighterCockpitPromptOpensShipCatalog() throws {
        let plan = AtlasQueryPlan(prompt: "Show fighter cockpits")
        let route = try XCTUnwrap(plan.specialistRoute)

        XCTAssertEqual(plan.goal, .browseSpecialist)
        XCTAssertEqual(route.feature, .shipParts)
        XCTAssertEqual(route.shipType, "Fighter")
        XCTAssertEqual(route.search, "Cockpit")
        XCTAssertNil(route.category)
    }

    func testFerriteBuildingPromptOpensHiddenNotEnabledCollection() throws {
        let plan = AtlasQueryPlan(prompt: "What can I build with Ferrite Dust?")
        let route = try XCTUnwrap(plan.specialistRoute)

        XCTAssertEqual(plan.goal, .browseSpecialist)
        XCTAssertEqual(route.feature, .buildingParts)
        XCTAssertEqual(route.includeNotEnabled, false)
        XCTAssertEqual(plan.localQuery, "Ferrite Dust")
    }

    @MainActor
    func testSpecialistCollectionModelAppliesPackedQuery() {
        let route = SpecialistRoute(
            feature: .fish,
            timeOfDay: "Night",
            biome: "Frozen",
            size: "Large",
            quality: "Legendary",
            needsStorm: true
        )
        let session = SpecialistCollectionModel(feature: .fish, route: route)
        XCTAssertEqual(session.timeOfDay, "Night")
        XCTAssertEqual(session.biome, "Frozen")
        XCTAssertEqual(session.needsStorm, true)
        XCTAssertEqual(session.size, "Large")
        XCTAssertEqual(session.quality, "Legendary")
        XCTAssertEqual(session.query.feature, .fish)
    }

    func testAppDestinationRoundTripsSpecialistQuery() throws {
        let route = SpecialistRoute(
            feature: .buildingParts,
            includeNotEnabled: false,
            requiredEntityType: "substance",
            requiredGameID: "FUEL1"
        )
        let encoded = try JSONEncoder().encode(AppDestination.specialist(route))
        let decoded = try JSONDecoder().decode(AppDestination.self, from: encoded)
        XCTAssertEqual(decoded, .specialist(route))
    }

    func testFilterActionOpensSpecialistRouteWithoutARecord() throws {
        let route = SpecialistRoute(feature: .fish, timeOfDay: "Night", biome: "Frozen")
        let ledger = EvidenceLedger(packIdentity: .preview)
        let resolved = try ActionResolver().resolve(
            proposal: .filter(route),
            ledger: ledger,
            packReleaseID: PackIdentity.preview.sourceCommitSHA,
            queryPlan: AtlasQueryPlan(prompt: "What can I catch at night on a frozen planet?"),
            capabilityBundleID: "core"
        )
        XCTAssertEqual(resolved.action, .filter(.specialist(route)))
        XCTAssertTrue(resolved.recordKeys.isEmpty)
    }

    func testCookingBrowseFollowUpOpensExistingPlanner() throws {
        XCTAssertEqual(
            Recipe.previewCooking.planDestination(),
            .recipePlan(type: "product", id: "FOOD_COOKED", quantity: 1)
        )
        let ledger = EvidenceLedger(packIdentity: .preview)
        let record = ledger.issue(payload: .recipe(.previewCooking), source: .packed)
        let proposed = DeterministicTurnPlanner.plan(
            prompt: "How do I cook food?",
            queryPlan: AtlasQueryPlan(prompt: "How do I cook food?"),
            bundle: ledger.bundle(turnID: "turn-1", ids: [record.evidenceID])
        )
        XCTAssertTrue(
            proposed.followUps.contains(.plan(type: "product", id: "FOOD_COOKED", quantity: 1))
        )
    }

    func testThreeChatPromptsOpenTheSameSpecialistDestinationWithOrWithoutTheModel() async throws {
        let catalog = try previewCatalog()
        let prompts: [(String, SpecialistFeature)] = [
            ("What can I catch at night on a frozen planet?", .fish),
            ("Show fighter cockpits", .shipParts),
            ("What can I build with Ferrite Dust?", .buildingParts),
        ]

        for (prompt, feature) in prompts {
            let unavailable = await reply(
                prompt: prompt,
                catalog: catalog,
                flags: .disabled,
                availability: .unavailable,
                proposedPlanner: DeterministicTurnPlanner()
            )
            let available = await reply(
                prompt: prompt,
                catalog: catalog,
                flags: .enabled,
                availability: .available,
                proposedPlanner: FixedTurnPlanner(plan: .empty)
            )

            XCTAssertEqual(unavailable.navigationDestination, available.navigationDestination, prompt)
            guard case .specialist(let route) = unavailable.navigationDestination else {
                XCTFail("Expected specialist destination for \(prompt)")
                continue
            }
            XCTAssertEqual(route.feature, feature, prompt)
            XCTAssertTrue(
                unavailable.followUps.contains { $0.intent == .openSpecialist(route) },
                prompt
            )
            if feature == .fish {
                XCTAssertEqual(route.timeOfDay, "Night")
                XCTAssertEqual(route.biome, "Frozen")
            }
            if feature == .shipParts {
                XCTAssertEqual(route.shipType, "Fighter")
                XCTAssertEqual(route.search, "Cockpit")
            }
            if feature == .buildingParts {
                XCTAssertEqual(route.includeNotEnabled, false)
                XCTAssertEqual(route.requiredGameID, "FUEL1")
                XCTAssertEqual(route.requiredEntityType, "substance")
            }
        }
    }

    func testCookingPromptKeepsOpenPlanFollowUp() async throws {
        let turn = await reply(prompt: "How do I cook food?", catalog: try previewCatalog())
        XCTAssertTrue(
            turn.followUps.contains {
                $0.intent == .plan(type: "product", id: "FOOD_COOKED", quantity: 1)
            }
        )
    }

    func testNightFrozenPromptDoesNotOpenOtherHistoryStory() async throws {
        let turn = await reply(
            prompt: "What can I catch at night on a frozen planet?",
            catalog: try previewCatalog()
        )
        XCTAssertEqual(turn.cards, [])
        guard case .specialist(let route) = turn.navigationDestination else {
            return XCTFail("Expected specialist fish destination")
        }
        XCTAssertEqual(route.feature, .fish)
        XCTAssertEqual(route.timeOfDay, "Night")
        XCTAssertEqual(route.biome, "Frozen")
        XCTAssertFalse(turn.text.localizedCaseInsensitiveContains("Other History"))
    }

    func testConditionOnlyNightFrozenStillOpensFish() throws {
        let plan = AtlasQueryPlan(prompt: "night on a frozen planet")
        let route = try XCTUnwrap(plan.specialistRoute)
        XCTAssertEqual(route.feature, .fish)
        XCTAssertEqual(route.timeOfDay, "Night")
        XCTAssertEqual(route.biome, "Frozen")
    }

    @MainActor
    func testFishSearchTokensMapOntoTimeAndBiomePickers() {
        let session = SpecialistCollectionModel(feature: .fish)
        session.interpretSearchInput("night frozen")
        XCTAssertEqual(session.timeOfDay, "Night")
        XCTAssertEqual(session.biome, "Frozen")
        XCTAssertEqual(session.search, "")
    }

    private func reply(
        prompt: String,
        catalog: SQLiteNMSCatalog,
        flags: GenerativeRoutingFlags = .disabled,
        availability: FoundationModelAvailability = .unavailable,
        proposedPlanner: any ProposedTurnPlanning = DeterministicTurnPlanner()
    ) async -> ValidatedAssistantTurn {
        let identity = try! await catalog.packIdentity()
        let engine = AtlasConversationEngine()
        return await engine.reply(
            ConversationTurnRequest(
                prompt: prompt,
                turnID: "turn-1",
                generation: 1,
                packIdentity: identity,
                catalog: catalog,
                snapshot: SourcePolicySnapshot(
                    liveAtlasCapabilityEnabled: false,
                    webSearchCapabilityEnabled: false,
                    packAvailable: true
                ),
                receipts: [],
                external: .empty,
                flags: flags,
                modelAvailability: availability,
                identifiers: UUIDIdentifierSource(),
                clock: clock
            ),
            queryPlanner: DeterministicModelPlanner(),
            proposedPlanner: proposedPlanner
        )
    }

    private func previewCatalog() throws -> SQLiteNMSCatalog {
        let url = try XCTUnwrap(
            Bundle(for: FeatureProjectionTests.self).url(forResource: "nms-reference", withExtension: "sqlite"),
            "The AtlasTests preview fixture is missing."
        )
        return SQLiteNMSCatalog(store: try SQLiteNMSStore(fileURL: url), packRole: "preview")
    }
}

private extension PackIdentity {
    static let preview = PackIdentity(
        sourceCommitSHA: "142d9ffd8078944722243398202f22cbef47cd02",
        packSchemaVersion: 2,
        contractVersion: 1,
        generatedAt: "2026-08-31T04:30:33Z",
        packRole: "preview"
    )
}

private extension Recipe {
    static let previewCooking = Recipe(
        recipeID: "cooking:product:FOOD_COOKED:0",
        recipeKind: "cooking",
        outputEntityType: "product",
        outputGameID: "FOOD_COOKED",
        outputAmount: "1",
        timeSeconds: "5",
        recipeType: "Nutrient Processor",
        recipeName: "Cooked Meat",
        sourceOrdinal: 0,
        sourceCommitSHA: PackIdentity.preview.sourceCommitSHA,
        ingredients: [],
        outputTitle: "Cooked Meat"
    )
}
