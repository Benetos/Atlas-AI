import XCTest
@testable import Atlas

final class Phase1BFoundationTests: XCTestCase {
    private let pack = PackIdentity.phase1B
    private let clock = FixedClock(date: Date(timeIntervalSince1970: 1_800_000_000))

    func testGlobalSettingDoesNotAuthorizeExternalSearch() {
        let plan = AtlasQueryPlan(prompt: "Search the web for current expedition")
        XCTAssertTrue(plan.requestsWeb)
        let snapshot = SourcePolicySnapshot(
            liveAtlasCapabilityEnabled: true,
            webSearchCapabilityEnabled: true,
            packAvailable: true
        )
        let decision = SourcePolicyDecision.decide(
            plan: plan,
            snapshot: snapshot,
            receipts: [],
            turnID: "turn-1",
            now: clock.now()
        )
        XCTAssertTrue(decision.webCapabilityEnabled)
        XCTAssertFalse(decision.authorizesWeb)
        XCTAssertTrue(decision.requiresWebConsent)
        XCTAssertFalse(decision.authorizesLive)
    }

    func testOneShotConsentReceiptAuthorizesOnlyMatchingQueryAndTurn() throws {
        let plan = AtlasQueryPlan(prompt: "Search the web for current expedition")
        let query = try OutboundQuery.derive(from: plan)
        var receipt = ExternalConsentReceipt(
            id: "r1",
            source: .web,
            normalizedOutboundQuery: query,
            originatingTurnID: "turn-1",
            issuedAt: clock.now(),
            expiresAt: clock.now().addingTimeInterval(120),
            consumed: false
        )
        let snapshot = SourcePolicySnapshot(
            liveAtlasCapabilityEnabled: false,
            webSearchCapabilityEnabled: true,
            packAvailable: true
        )
        let authorized = SourcePolicyDecision.decide(
            plan: plan,
            snapshot: snapshot,
            receipts: [receipt],
            turnID: "turn-1",
            now: clock.now()
        )
        XCTAssertTrue(authorized.authorizesWeb)

        let otherTurn = SourcePolicyDecision.decide(
            plan: plan,
            snapshot: snapshot,
            receipts: [receipt],
            turnID: "turn-2",
            now: clock.now()
        )
        XCTAssertFalse(otherTurn.authorizesWeb)

        receipt.consume()
        let reused = SourcePolicyDecision.decide(
            plan: plan,
            snapshot: snapshot,
            receipts: [receipt],
            turnID: "turn-1",
            now: clock.now()
        )
        XCTAssertFalse(reused.authorizesWeb)
    }

    func testEvidenceIDsComeFromSourceRecordAndDigestAndRejectStaleOrUnknown() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let first = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        let again = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        XCTAssertEqual(first.evidenceID, again.evidenceID)
        XCTAssertEqual(first.recordKey, .entity(type: "substance", id: "LAND1"))
        XCTAssertNotEqual(first.evidenceID, first.recordKey.canonical)

        XCTAssertEqual(try ledger.resolve(first.evidenceID).recordKey.canonical, "entity:substance:LAND1")
        XCTAssertThrowsError(try ledger.resolve("deadbeef")) { error in
            XCTAssertEqual(error as? EvidenceError, .unknownID("deadbeef"))
        }

        let staleID = first.evidenceID
        ledger.reset(packIdentity: pack)
        XCTAssertThrowsError(try ledger.resolve(staleID)) { error in
            XCTAssertEqual(error as? EvidenceError, .staleID(staleID))
        }
    }

    func testPersistedRoutesUseRecordKeysNotEvidenceIDs() {
        let key = RecordKey.entity(type: "substance", id: "LAND1")
        XCTAssertEqual(key.destination, .entity(type: "substance", id: "LAND1"))
        XCTAssertFalse(key.canonical.contains("evidence"))
    }

    func testDerivedEvidenceUsesCalculatedProvenanceAndRejectsBadAncestry() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let parent = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        let knowledge = LocalKnowledgeToolRegistry(
            database: LocalDatabaseToolRegistry(catalog: Self.catalog(), ledger: ledger, packIdentity: pack)
        )
        let derived = try knowledge.scaleQuantity(
            quantity: 12,
            multiplier: 2,
            parentEvidenceIDs: [parent.evidenceID],
            ledger: ledger,
            packIdentity: pack
        )
        XCTAssertEqual(derived.output, "24")
        XCTAssertTrue(derived.provenanceLabel.hasPrefix("Calculated from pack"))
        XCTAssertNotEqual(derived.provenanceLabel, "Packed")

        XCTAssertThrowsError(
            try knowledge.scaleQuantity(
                quantity: 12,
                multiplier: 2,
                parentEvidenceIDs: ["missing-parent"],
                ledger: ledger,
                packIdentity: pack
            )
        )
    }

    func testClaimValidatorRejectsUnsupportedStaleAlteredAndUnknownFacts() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let entity = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        let validator = ClaimValidator()

        XCTAssertThrowsError(
            try validator.validate(
                claim: ProposedClaim(kindName: "invented-stat", facts: [
                    FactRef(evidenceID: entity.evidenceID, field: "title"),
                ]),
                ledger: ledger
            )
        ) { error in
            XCTAssertEqual(error as? ClaimValidationError, .unsupportedKind("invented-stat"))
        }

        XCTAssertThrowsError(
            try validator.validate(
                claim: ProposedClaim(kind: .entityExists, facts: [
                    FactRef(evidenceID: "missing", field: "title"),
                ]),
                ledger: ledger
            )
        )

        let staleID = entity.evidenceID
        ledger.reset(packIdentity: pack)
        XCTAssertThrowsError(
            try validator.validate(
                claim: ProposedClaim(kind: .entityExists, facts: [
                    FactRef(evidenceID: staleID, field: "title"),
                ]),
                ledger: ledger
            )
        ) { error in
            XCTAssertEqual(error as? ClaimValidationError, .staleFact(staleID))
        }

        let freshLedger = EvidenceLedger(packIdentity: pack)
        let freshRecipe = freshLedger.issue(payload: .recipe(.phase1BCarbon), source: .packed)
        XCTAssertThrowsError(
            try validator.validate(
                claim: ProposedClaim(kind: .recipeProduces, facts: [
                    FactRef(evidenceID: freshRecipe.evidenceID, field: "outputAmount", quantity: 99),
                ]),
                ledger: freshLedger
            )
        ) { error in
            XCTAssertEqual(error as? ClaimValidationError, .alteredQuantity(expected: 1, actual: 99))
        }
    }

    func testInvalidModelPlanFallsBackToDeterministicGroundedText() async {
        let catalog = Self.catalog()
        let engine = AtlasConversationEngine()
        let malicious = FixedTurnPlanner(
            plan: ProposedTurnPlan(
                claims: [ProposedClaim(kindName: "made-up", facts: [])],
                followUps: [],
                actions: [GeneratedActionProposal(kind: "teleport", payload: [:])],
                tone: "Trust me, Ferrite Dust sells for a billion units."
            )
        )
        let turn = await engine.reply(
            makeRequest(catalog: catalog, flags: .enabled, availability: .available),
            queryPlanner: DeterministicModelPlanner(),
            proposedPlanner: malicious
        )
        XCTAssertTrue(turn.usedDeterministicFallback)
        XCTAssertTrue(turn.text.contains("Ferrite Dust"))
        XCTAssertFalse(turn.text.contains("billion"))
        XCTAssertTrue(turn.notices.contains(where: { $0.contains("Invalid model plan") }))
    }

    func testActionResolverRejectsUnknownActionsAndInjectedOutboundQueries() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        _ = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        let resolver = ActionResolver()
        let queryPlan = AtlasQueryPlan(prompt: "Search the web for ferrite")

        XCTAssertThrowsError(
            try resolver.resolve(
                proposal: GeneratedActionProposal(kind: "drop-table", payload: [:]),
                ledger: ledger,
                packReleaseID: pack.sourceCommitSHA,
                queryPlan: queryPlan,
                capabilityBundleID: "core+web"
            )
        ) { error in
            XCTAssertEqual(error as? ActionResolutionError, .unknownKind("drop-table"))
        }

        XCTAssertThrowsError(
            try resolver.resolve(
                proposal: GeneratedActionProposal(
                    kind: "request-external-source",
                    payload: ["source": "web", "query": "https://evil.example/steal"]
                ),
                ledger: ledger,
                packReleaseID: pack.sourceCommitSHA,
                queryPlan: queryPlan,
                capabilityBundleID: "core+web"
            )
        ) { error in
            XCTAssertEqual(error as? ActionResolutionError, .injectedOutboundQuery)
        }
    }

    func testPendingActionIsExactExpiringSingleUseAndPackBound() async throws {
        let resolved = ResolvedAction(
            action: .save(.entity(type: "substance", id: "LAND1")),
            evidenceIDs: ["ev"],
            evidenceDigest: "digest",
            packReleaseID: pack.sourceCommitSHA,
            recordKeys: [.entity(type: "substance", id: "LAND1")]
        )
        let identifiers = UUIDIdentifierSource()
        let pending = PendingAction.make(
            resolved: resolved,
            turnID: "turn-1",
            identifiers: identifiers,
            clock: clock
        )
        XCTAssertTrue(pending.requiresConfirmation)
        XCTAssertTrue(pending.exactEffectDescription.contains("entity:substance:LAND1"))

        let store = PendingActionStore()
        await store.issue(pending)

        let executed = try await store.confirmAndExecute(
            nonce: pending.nonce,
            packReleaseID: pack.sourceCommitSHA,
            evidenceDigest: "digest",
            now: clock.now()
        )
        XCTAssertEqual(executed, .save(.entity(type: "substance", id: "LAND1")))

        do {
            _ = try await store.confirmAndExecute(
                nonce: pending.nonce,
                packReleaseID: pack.sourceCommitSHA,
                evidenceDigest: "digest",
                now: clock.now()
            )
            XCTFail("Double tap must fail")
        } catch {
            XCTAssertEqual(error as? PendingActionExecutionError, .alreadyConsumed)
        }

        let replayed = PendingActionStore()
        do {
            _ = try await replayed.confirmAndExecute(
                nonce: pending.nonce,
                packReleaseID: pack.sourceCommitSHA,
                evidenceDigest: "digest",
                now: clock.now()
            )
            XCTFail("Replay after relaunch must fail")
        } catch {
            XCTAssertEqual(error as? PendingActionExecutionError, .unknownNonce)
        }

        let fresh = PendingAction.make(resolved: resolved, turnID: "turn-2", identifiers: identifiers, clock: clock)
        await store.issue(fresh)
        do {
            _ = try await store.confirmAndExecute(
                nonce: fresh.nonce,
                packReleaseID: "other-pack",
                evidenceDigest: "digest",
                now: clock.now()
            )
            XCTFail("Pack mismatch must fail")
        } catch {
            XCTAssertEqual(error as? PendingActionExecutionError, .packMismatch)
        }

        let expiring = PendingAction.make(resolved: resolved, turnID: "turn-3", identifiers: identifiers, clock: clock)
        await store.issue(expiring)
        do {
            _ = try await store.confirmAndExecute(
                nonce: expiring.nonce,
                packReleaseID: pack.sourceCommitSHA,
                evidenceDigest: "digest",
                now: clock.now().addingTimeInterval(ConversationBounds.pendingActionTTL + 1)
            )
            XCTFail("Expired confirmation must fail")
        } catch {
            XCTAssertEqual(error as? PendingActionExecutionError, .expired)
        }

        let declined = PendingAction.make(resolved: resolved, turnID: "turn-4", identifiers: identifiers, clock: clock)
        await store.issue(declined)
        try await store.decline(nonce: declined.nonce)
        do {
            _ = try await store.confirmAndExecute(
                nonce: declined.nonce,
                packReleaseID: pack.sourceCommitSHA,
                evidenceDigest: "digest",
                now: clock.now()
            )
            XCTFail("Declined action must fail")
        } catch {
            XCTAssertEqual(error as? PendingActionExecutionError, .declined)
        }
    }

    func testToolBoundsRejectOversizedQuerySearchLimitAndQuantityOverflow() async throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let tools = LocalDatabaseToolRegistry(catalog: Self.catalog(), ledger: ledger, packIdentity: pack)
        tools.beginTurn()

        let tooLong = String(repeating: "a", count: ConversationBounds.maxQueryUnicodeScalars + 1)
        let query = try await tools.invoke(LocalToolCall(name: "search_entities", query: tooLong))
        XCTAssertEqual(query.status, .rejected)

        let search = try await tools.invoke(
            LocalToolCall(name: "search_entities", query: "Ferrite", limit: ConversationBounds.maxSearchResults + 1)
        )
        XCTAssertEqual(search.status, .rejected)

        XCTAssertThrowsError(try Quantity.checked(0))
        XCTAssertThrowsError(try Quantity.checked(1_000_000))
        XCTAssertThrowsError(try Quantity.product(999_999, 2))
        XCTAssertEqual(try Quantity.product(12, 2), 24)

        let huge = String(repeating: "x", count: ConversationBounds.maxDetailPayloadBytes + 1)
        let bloated = ContentRecord(
            dataset: "stories",
            externalID: "huge",
            sourceOrdinal: 0,
            displayName: "Huge",
            payload: huge,
            sourceCommitSHA: pack.sourceCommitSHA
        )
        let detailTools = LocalDatabaseToolRegistry(
            catalog: FixtureNMSCatalog(identity: pack, entities: [], recipes: [], records: [bloated]),
            ledger: EvidenceLedger(packIdentity: pack),
            packIdentity: pack
        )
        let detail = try await detailTools.invoke(
            LocalToolCall(name: "get_content", gameID: "huge", dataset: "stories", sourceOrdinal: 0)
        )
        XCTAssertEqual(detail.status, .rejected)
    }

    func testCoreToolsAreFixedAndTypedAndKnowledgeRegistryStaysLocal() async throws {
        XCTAssertEqual(
            LocalDatabaseToolRegistry.expectedNames,
            [
                "search_entities",
                "get_entity",
                "search_recipes",
                "get_recipe",
                "recipes_for",
                "recipes_using",
                "search_content",
                "get_content",
                "get_pack_provenance",
            ]
        )
        let ledger = EvidenceLedger(packIdentity: pack)
        let tools = LocalKnowledgeToolRegistry(
            database: LocalDatabaseToolRegistry(catalog: Self.catalog(), ledger: ledger, packIdentity: pack)
        )
        tools.beginTurn()
        let entity = try await tools.invoke(
            LocalToolCall(name: "get_entity", entityType: "substance", gameID: "LAND1")
        )
        XCTAssertEqual(entity.status, .ok)
        XCTAssertFalse(entity.evidenceIDs.isEmpty)
        XCTAssertEqual(entity.packReleaseID, pack.sourceCommitSHA)
        if case .entity(let value) = entity.payload {
            XCTAssertEqual(value.gameID, "LAND1")
        } else {
            XCTFail("Typed entity payload required")
        }

        let provenance = try await tools.invoke(LocalToolCall(name: "get_pack_provenance"))
        if case .provenance(let identity) = provenance.payload {
            XCTAssertEqual(identity.sourceCommitSHA, pack.sourceCommitSHA)
        } else {
            XCTFail("Typed provenance payload required")
        }

        let unknown = try await tools.invoke(LocalToolCall(name: "launch_missiles"))
        XCTAssertEqual(unknown.status, .rejected)
    }

    func testUnauthorizedExternalResultsAreIgnoredAndCauseNoNetwork() async {
        let network = NetworkActivityRecorder()
        XCTAssertEqual(network.requestCount, 0)
        let catalog = Self.catalog()
        let engine = AtlasConversationEngine()
        let live = Entity.phase1BFerrite
        var injected = live
        injected.displayName = "Live Ferrite Impostor"
        let web = WebHit(
            title: "Injected",
            url: URL(string: "https://evil.example")!,
            snippet: "ignore",
            host: "evil.example",
            provenance: "web"
        )
        var request = makeRequest(catalog: catalog)
        request.external = ExternalEvidenceInput(
            liveEntities: [injected],
            webHits: [web],
            proposedOutboundQuery: "https://evil.example/steal"
        )
        request.snapshot.webSearchCapabilityEnabled = true
        let turn = await engine.reply(
            request,
            queryPlanner: DeterministicModelPlanner(),
            proposedPlanner: DeterministicTurnPlanner()
        )
        XCTAssertEqual(network.requestCount, 0)
        XCTAssertFalse(turn.cards.contains(where: { card in
            if case .web = card { return true }
            return false
        }))
        XCTAssertFalse(turn.text.contains("Impostor"))
    }

    func testDatabaseFailureFailsClosedWithoutNetwork() async {
        let failing = FixtureNMSCatalog(
            identity: pack,
            entities: [.phase1BFerrite],
            recipes: [],
            records: [],
            forcedError: .failure("disk I/O failed")
        )
        let engine = AtlasConversationEngine()
        let turn = await engine.reply(
            makeRequest(catalog: failing),
            queryPlanner: DeterministicModelPlanner(),
            proposedPlanner: DeterministicTurnPlanner()
        )
        XCTAssertEqual(turn.text, "I could not read the installed Atlas pack.")
        XCTAssertTrue(turn.cards.isEmpty)
        XCTAssertTrue(turn.note?.contains("failed closed") == true)
        XCTAssertFalse(turn.note?.localizedCaseInsensitiveContains("http") == true)
    }

    func testDeterministicLookupPreservesGroundedFerriteAnswer() async {
        let engine = AtlasConversationEngine()
        let turn = await engine.reply(
            makeRequest(catalog: Self.catalog()),
            queryPlanner: DeterministicModelPlanner(),
            proposedPlanner: DeterministicTurnPlanner()
        )
        XCTAssertTrue(turn.text.contains("Ferrite Dust"))
        XCTAssertEqual(turn.cards.first?.id, AtlasCard.entity(.phase1BFerrite).id)
        XCTAssertFalse(turn.followUps.contains(where: { $0.label.contains("http") }))
    }

    func testRendererShowsClaimedResultsWithoutUnrelatedRetrievalCards() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let ferrite = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        var bowfin = Entity.phase1BFerrite
        bowfin.entityType = "product"
        bowfin.gameID = "FISH"
        bowfin.displayName = "Ferrite Bowfin"
        _ = ledger.issue(payload: .entity(bowfin), source: .packed)
        _ = ledger.issue(payload: .recipe(.phase1BCarbon), source: .packed)
        let claims = try ClaimValidator().validate(
            plan: ProposedTurnPlan(
                claims: [ProposedClaim(kind: .entityDescription, facts: [
                    FactRef(evidenceID: ferrite.evidenceID, field: "description"),
                ])],
                followUps: [], actions: [], tone: nil
            ),
            ledger: ledger
        )

        let rendered = GroundedRenderer().render(
            claims: claims, queryPlan: AtlasQueryPlan(prompt: "Ferrite Dust"),
            bundle: ledger.bundle(turnID: "turn-1"), followUps: [], tone: nil,
            notices: [], usedDeterministicFallback: true
        )

        XCTAssertEqual(rendered.cards.map(\.id), [AtlasCard.entity(.phase1BFerrite).id])
        XCTAssertTrue(rendered.text.contains("A common metallic substance."))
        XCTAssertFalse(rendered.text.contains("Bowfin"))
    }

    func testRendererDeduplicatesBeforeBrowsingLimitAndCount() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let records = (0..<ConversationBounds.answerEntityLimit).map { index in
            var entity = Entity.phase1BFerrite
            entity.gameID = "SUBSTANCE_\(index)"
            entity.displayName = "Substance \(index)"
            return ledger.issue(payload: .entity(entity), source: .packed)
        }
        let claim = try ClaimValidator().validate(
            claim: ProposedClaim(kind: .browseCount, facts: [
                FactRef(evidenceID: records[0].evidenceID, field: "count"),
            ]),
            ledger: ledger
        )
        var bundle = ledger.bundle(turnID: "turn-1")
        bundle.records = Array(repeating: records[0], count: ConversationBounds.answerEntityLimit) + records
        let rendered = GroundedRenderer().render(
            claims: [claim], queryPlan: AtlasQueryPlan(prompt: "Show all substances"),
            bundle: bundle, followUps: [], tone: nil, notices: [], usedDeterministicFallback: true
        )

        XCTAssertEqual(rendered.cards.count, ConversationBounds.answerEntityLimit)
        XCTAssertEqual(Set(rendered.cards.map(\.id)).count, ConversationBounds.answerEntityLimit)
        XCTAssertTrue(rendered.text.contains("\(ConversationBounds.answerEntityLimit) substances"))
    }

    func testRendererAsksToChooseBetweenAmbiguousMatches() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let ferrite = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        var bowfin = Entity.phase1BFerrite
        bowfin.entityType = "product"
        bowfin.gameID = "FISH"
        bowfin.displayName = "Ferrite Bowfin"
        let fish = ledger.issue(payload: .entity(bowfin), source: .packed)
        let claims = try [ferrite, fish].map { record in
            try ClaimValidator().validate(
                claim: ProposedClaim(kind: .entityExists, facts: [
                    FactRef(evidenceID: record.evidenceID, field: "title"),
                ]),
                ledger: ledger
            )
        }
        let rendered = GroundedRenderer().render(
            claims: claims, queryPlan: AtlasQueryPlan(prompt: "Ferrite"),
            bundle: ledger.bundle(turnID: "turn-1"), followUps: [], tone: nil,
            notices: [], usedDeterministicFallback: true
        )

        XCTAssertEqual(rendered.text, "I found a few matching items. Choose the one you mean.")
        XCTAssertEqual(rendered.cards.map(\.id), [AtlasCard.entity(.phase1BFerrite).id, AtlasCard.entity(bowfin).id])
    }

    func testRendererShowsPlanTargetAndMultilineChecklistWithoutHelperCards() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        var circuit = Entity.phase1BFerrite
        circuit.entityType = "product"
        circuit.gameID = "CIRCUIT"
        circuit.displayName = "Circuit Board"
        let target = ledger.issue(payload: .entity(circuit), source: .packed)
        let helper = ledger.issue(payload: .entity(.phase1BFerrite), source: .packed)
        var bowfin = circuit
        bowfin.gameID = "FISH"
        bowfin.displayName = "Ferrite Bowfin"
        let unrelated = ledger.issue(payload: .entity(bowfin), source: .packed)
        let plan = ledger.issue(
            payload: .derived(rendererPlanEvidence(inputs: [
                "target": circuit.id,
                "targetTitle": circuit.title,
                "rootKind": "crafted",
                "checklistSummary": "2400× Frost Crystal; 1200× Solanium",
            ])),
            source: .calculated
        )
        let claims = try ClaimValidator().validate(
            plan: ProposedTurnPlan(
                claims: [
                    ProposedClaim(kind: .entityExists, facts: [FactRef(evidenceID: helper.evidenceID, field: "title")]),
                    ProposedClaim(kind: .derivedTotal, facts: [FactRef(evidenceID: plan.evidenceID, field: "output", quantity: 12)]),
                ],
                followUps: [], actions: [], tone: nil
            ),
            ledger: ledger
        )
        var bundle = ledger.bundle(turnID: "turn-1")
        bundle.records = [unrelated, helper, target, unrelated, target, plan]
        let followUp = FollowUpIntent.plan(type: "product", id: "CIRCUIT", quantity: 12)
        let rendered = GroundedRenderer().render(
            claims: claims, queryPlan: AtlasQueryPlan(prompt: "I need 12 Circuit Boards"),
            bundle: bundle, followUps: [followUp, followUp], tone: nil,
            notices: [], usedDeterministicFallback: true
        )

        XCTAssertEqual(rendered.text, "Plan for 12× Circuit Board\n\nGather:\n• 2400× Frost Crystal\n• 1200× Solanium")
        XCTAssertEqual(rendered.cards.map(\.id), [AtlasCard.entity(circuit).id])
        XCTAssertEqual(rendered.chips.count, 1)
        XCTAssertFalse(rendered.text.contains("recipe-graph"))
        XCTAssertTrue(rendered.note?.contains("Calculated from pack") == true)
    }

    func testRendererKeepsPartialPlanCaveatsAndWorksWithoutTargetCard() throws {
        let ledger = EvidenceLedger(packIdentity: pack)
        let evidence = ledger.issue(
            payload: .derived(rendererPlanEvidence(inputs: [
                "target": "product:CIRCUIT", "targetTitle": "Circuit Board", "rootKind": "crafted",
                "checklistSummary": "24× Intermediate Part", "truncated": "true", "cycleCount": "1",
                "notices": "Selected recipe is not in this snapshot.\nSelected recipe is not in this snapshot.",
            ])),
            source: .calculated
        )
        let claim = try ClaimValidator().validate(
            claim: ProposedClaim(kind: .derivedTotal, facts: [
                FactRef(evidenceID: evidence.evidenceID, field: "output", quantity: 12),
            ]),
            ledger: ledger
        )
        let rendered = GroundedRenderer().render(
            claims: [claim], queryPlan: AtlasQueryPlan(prompt: "I need 12 Circuit Boards"),
            bundle: ledger.bundle(turnID: "turn-1"), followUps: [], tone: nil,
            notices: [], usedDeterministicFallback: true
        )

        XCTAssertTrue(rendered.text.hasPrefix("Partial plan for 12× Circuit Board"))
        XCTAssertTrue(rendered.text.contains("\n• 24× Intermediate Part"))
        XCTAssertTrue(rendered.cards.isEmpty)
        XCTAssertTrue(rendered.note?.contains("Some listed items may still be craftable") == true)
        XCTAssertTrue(rendered.note?.contains("recipes loop back") == true)
        XCTAssertEqual(rendered.note?.components(separatedBy: "Selected recipe is not in this snapshot.").count, 2)
    }

    func testRendererDoesNotPresentMissingRecipeAsIngredientChecklist() throws {
        for rootKind in ["leaf", "missingRecipe"] {
            let ledger = EvidenceLedger(packIdentity: pack)
            let evidence = ledger.issue(
                payload: .derived(rendererPlanEvidence(inputs: [
                    "target": "product:CIRCUIT", "targetTitle": "Circuit Board",
                    "rootKind": rootKind, "checklistSummary": "12× Circuit Board",
                ])),
                source: .calculated
            )
            let claim = try ClaimValidator().validate(
                claim: ProposedClaim(kind: .derivedTotal, facts: [
                    FactRef(evidenceID: evidence.evidenceID, field: "output", quantity: 12),
                ]),
                ledger: ledger
            )
            let rendered = GroundedRenderer().render(
                claims: [claim], queryPlan: AtlasQueryPlan(prompt: "I need 12 Circuit Boards"),
                bundle: ledger.bundle(turnID: "turn-1"), followUps: [], tone: nil,
                notices: [], usedDeterministicFallback: true
            )

            XCTAssertTrue(rendered.text.contains("12× Circuit Board"))
            XCTAssertFalse(rendered.text.contains("Gather:"))
            XCTAssertTrue(rendered.text.contains(rootKind == "leaf" ? "no recipe" : "selected recipe"))
        }
    }

    private func rendererPlanEvidence(inputs: [String: String]) -> DerivedEvidence {
        DerivedEvidence.make(
            engineName: ComputedRecipePlan.engineName,
            engineVersion: ComputedRecipePlan.engineVersion,
            normalizedInputs: inputs,
            parentEvidenceIDs: [],
            packReleaseID: pack.sourceCommitSHA,
            output: "12"
        )
    }

    func testCancellationDuringResolutionDropsTheTurn() async {
        let hanging = HangingCatalog(identity: pack, entities: [.phase1BFerrite])
        let engine = AtlasConversationEngine()
        let task = Task {
            await engine.reply(
                makeRequest(catalog: hanging, prompt: "Ferrite Dust"),
                queryPlanner: DeterministicModelPlanner(),
                proposedPlanner: DeterministicTurnPlanner()
            )
        }
        try? await Task.sleep(for: .milliseconds(80))
        await engine.cancelResolution()
        task.cancel()
        let turn = await task.value
        XCTAssertTrue(turn.notices.contains("Cancelled.") || turn.note == "Cancelled.")
        XCTAssertTrue(turn.cards.isEmpty)
    }

    func testRecipeExpansionBoundsAreLocked() throws {
        let bounds = RecipeExpansionBounds.current
        XCTAssertEqual(bounds.depth, 12)
        XCTAssertEqual(bounds.alternativesPerNode, 5)
        XCTAssertEqual(bounds.maxVisitedNodes, 500)
        XCTAssertEqual(bounds.budgetMilliseconds, 750)
        XCTAssertThrowsError(try bounds.rejectIfExceeded(depth: 13, nodes: 1, elapsedMilliseconds: 1))
        XCTAssertNoThrow(try bounds.rejectIfExceeded(depth: 12, nodes: 500, elapsedMilliseconds: 750))
    }

    private func makeRequest(
        catalog: any NMSCatalog,
        prompt: String = "Ferrite Dust",
        flags: GenerativeRoutingFlags = .disabled,
        availability: FoundationModelAvailability = .unavailable
    ) -> ConversationTurnRequest {
        ConversationTurnRequest(
            prompt: prompt,
            turnID: "turn-1",
            generation: 1,
            packIdentity: pack,
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
        )
    }

    private static func catalog() -> FixtureNMSCatalog {
        FixtureNMSCatalog(
            identity: .phase1B,
            entities: [.phase1BFerrite],
            recipes: [.phase1BCarbon],
            records: []
        )
    }
}

private struct HangingCatalog: NMSCatalog {
    var identity: PackIdentity
    var entities: [Entity]

    func packIdentity() async throws -> PackIdentity { identity }
    func entity(type: String, id: String) async throws -> Entity {
        try await wait()
        guard let entity = entities.first(where: { $0.entityType == type && $0.gameID == id }) else {
            throw CatalogError.notFound(.entity(type: type, id: id))
        }
        return entity
    }
    func recipe(id: String) async throws -> Recipe {
        try await wait()
        throw CatalogError.notFound(.recipe(id: id))
    }
    func content(dataset: String, id: String, sourceOrdinal: Int) async throws -> ContentRecord {
        try await wait()
        throw CatalogError.notFound(.content(dataset: dataset, id: id, sourceOrdinal: sourceOrdinal))
    }
    func recipesProducing(type: String, id: String) async throws -> [Recipe] {
        try await wait()
        return []
    }
    func recipesUsing(type: String, id: String) async throws -> [Recipe] {
        try await wait()
        return []
    }
    func searchEntities(query: String, type: String?, limit: Int) async throws -> [Entity] {
        try await wait()
        return entities
    }
    func searchRecipes(query: String, kind: String?, limit: Int) async throws -> [Recipe] {
        try await wait()
        return []
    }
    func searchContent(query: String, dataset: String?, limit: Int) async throws -> [ContentRecord] {
        try await wait()
        return []
    }
    func entities(type: String, limit: Int, offset: Int) async throws -> [Entity] {
        try await wait()
        return entities
    }
    func recipes(kind: String?, limit: Int, offset: Int) async throws -> [Recipe] {
        try await wait()
        return []
    }
    func contentRecords(dataset: String, limit: Int, offset: Int) async throws -> [ContentRecord] {
        try await wait()
        return []
    }

    private func wait() async throws {
        try await Task.sleep(for: .seconds(2))
    }
}

private extension PackIdentity {
    static let phase1B = PackIdentity(
        sourceCommitSHA: "142d9ffd8078944722243398202f22cbef47cd02",
        packSchemaVersion: 1,
        contractVersion: 1,
        generatedAt: "2026-08-31T04:30:33Z",
        packRole: "preview"
    )
}

private extension Entity {
    static let phase1BFerrite = Entity(
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
        sourceCommitSHA: PackIdentity.phase1B.sourceCommitSHA
    )
}

private extension Recipe {
    static let phase1BCarbon = Recipe(
        recipeID: "refining:substance:LAND1:0",
        recipeKind: "refining",
        outputEntityType: "substance",
        outputGameID: "FUEL1",
        outputAmount: "1",
        timeSeconds: nil,
        recipeType: nil,
        recipeName: nil,
        sourceOrdinal: 0,
        sourceCommitSHA: PackIdentity.phase1B.sourceCommitSHA,
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
