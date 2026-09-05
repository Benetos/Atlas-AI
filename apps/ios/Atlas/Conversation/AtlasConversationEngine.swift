import Foundation

struct ConversationTurnRequest: Sendable {
    var prompt: String
    var turnID: String
    var generation: UInt64
    var packIdentity: PackIdentity
    var catalog: any NMSCatalog
    var snapshot: SourcePolicySnapshot
    var receipts: [ExternalConsentReceipt]
    var external: ExternalEvidenceInput
    var flags: GenerativeRoutingFlags
    var modelAvailability: FoundationModelAvailability
    var identifiers: any IdentifierSource
    var clock: any Clock
}

struct ConversationContext: Equatable, Sendable {
    var recentTurnIDs: [String] = []
    var focusedRecordKeys: [RecordKey] = []
    var lastEvidenceDigest: String?
    var lastPackReleaseID: String?
}

actor AtlasConversationEngine {
    private var packReleaseID: String?
    private var capabilityBundleID: String?
    private var ledger: EvidenceLedger?
    private var pending = PendingActionStore()
    private var context = ConversationContext()
    private var currentGeneration: UInt64 = 0
    private var cancelledDuringResolution = false

    func handlePackChange(_ identity: PackIdentity) async {
        packReleaseID = identity.sourceCommitSHA
        ledger = EvidenceLedger(packIdentity: identity)
        await pending.resetForPackChange()
        context.focusedRecordKeys = []
        context.lastEvidenceDigest = nil
        context.lastPackReleaseID = identity.sourceCommitSHA
        currentGeneration += 1
    }

    func cancelResolution() async {
        cancelledDuringResolution = true
        await pending.cancelAll()
        currentGeneration += 1
    }

    func confirm(nonce: String, packReleaseID: String, evidenceDigest: String, now: Date) async throws -> AtlasAction {
        try await pending.confirmAndExecute(
            nonce: nonce,
            packReleaseID: packReleaseID,
            evidenceDigest: evidenceDigest,
            now: now
        )
    }

    func decline(nonce: String) async throws {
        try await pending.decline(nonce: nonce)
    }

    func reply(
        _ request: ConversationTurnRequest,
        queryPlanner: any ModelPlanning,
        proposedPlanner: any ProposedTurnPlanning
    ) async -> ValidatedAssistantTurn {
        cancelledDuringResolution = false
        currentGeneration = request.generation
        let policy = SourcePolicyDecision.decide(
            plan: await queryPlanner.plan(prompt: request.prompt),
            snapshot: request.snapshot,
            receipts: request.receipts,
            turnID: request.turnID,
            now: request.clock.now()
        )
        let queryPlan = await queryPlanner.plan(prompt: request.prompt)
        await ensureSession(
            packReleaseID: request.packIdentity.sourceCommitSHA,
            capabilityBundleID: policy.capabilityBundleID,
            packIdentity: request.packIdentity
        )
        guard let ledger else {
            return failClosed(request: request, notice: "Local data failed closed; Atlas did not substitute a network source.")
        }

        if !policy.allowsLocal {
            return failClosed(request: request, notice: "Local data failed closed; Atlas did not substitute a network source.")
        }

        let tools = LocalKnowledgeToolRegistry(
            database: LocalDatabaseToolRegistry(
                catalog: request.catalog,
                ledger: ledger,
                packIdentity: request.packIdentity
            )
        )
        tools.beginTurn()

        do {
            try Task.checkCancellation()
            let collected = try await collectLocal(
                plan: queryPlan,
                tools: tools,
                catalog: request.catalog
            )
            try Task.checkCancellation()
            if cancelledDuringResolution || currentGeneration != request.generation {
                return cancelledTurn(request: request)
            }

            ingestAuthorizedExternal(
                request.external,
                policy: policy,
                queryPlan: queryPlan,
                ledger: ledger
            )

            var notices: [String] = []
            if queryPlan.requestsLive && !policy.authorizesLive {
                if !policy.liveCapabilityEnabled {
                    notices.append("Live Atlas is off. Showing the installed pack only.")
                } else if policy.requiresLiveConsent {
                    notices.append("Live Atlas needs one-shot consent for this query.")
                }
            }
            if queryPlan.requestsWeb && !policy.authorizesWeb {
                if !policy.webCapabilityEnabled {
                    notices.append("Web search is off. Showing the installed pack only.")
                } else if policy.requiresWebConsent {
                    notices.append("Web search needs one-shot consent for this query.")
                }
            }
            if request.external.proposedOutboundQuery != nil,
               let proposed = request.external.proposedOutboundQuery,
               !OutboundQuery.matchesUserDerived(proposed, plan: queryPlan) {
                notices.append("Ignored an injected outbound query.")
            }

            let bundle = ledger.bundle(turnID: request.turnID)
            var usedFallback = false
            var proposed: ProposedTurnPlan
            if request.flags.modelProposedPlansEnabled,
               request.modelAvailability == .available {
                proposed = await proposedPlanner.propose(
                    prompt: request.prompt,
                    queryPlan: queryPlan,
                    bundle: bundle,
                    ledger: ledger
                )
            } else {
                proposed = DeterministicTurnPlanner.plan(
                    prompt: request.prompt,
                    queryPlan: queryPlan,
                    bundle: bundle
                )
                usedFallback = request.modelAvailability != .available
            }

            let validator = ClaimValidator()
            let claims: [ValidatedClaim]
            do {
                claims = try validator.validate(plan: proposed, ledger: ledger)
            } catch {
                proposed = DeterministicTurnPlanner.plan(
                    prompt: request.prompt,
                    queryPlan: queryPlan,
                    bundle: bundle
                )
                claims = (try? validator.validate(plan: proposed, ledger: ledger)) ?? []
                usedFallback = true
                notices.append("Invalid model plan. Showing the grounded local answer.")
            }

            if cancelledDuringResolution {
                return cancelledTurn(request: request)
            }

            var allowed: [ResolvedAction] = []
            var pendingActions: [PendingAction] = []
            if request.flags.generatedActionsEnabled {
                let resolver = ActionResolver()
                let actionPolicy = ActionPolicy()
                for proposal in proposed.actions {
                    do {
                        let resolved = try resolver.resolve(
                            proposal: proposal,
                            ledger: ledger,
                            packReleaseID: request.packIdentity.sourceCommitSHA,
                            queryPlan: queryPlan,
                            capabilityBundleID: policy.capabilityBundleID
                        )
                        switch actionPolicy.decide(resolved) {
                        case .allow:
                            allowed.append(resolved)
                        case .confirm:
                            let pendingAction = PendingAction.make(
                                resolved: resolved,
                                turnID: request.turnID,
                                identifiers: request.identifiers,
                                clock: request.clock
                            )
                            await pending.issue(pendingAction)
                            pendingActions.append(pendingAction)
                        case .deny(let reason):
                            notices.append(reason)
                        }
                    } catch {
                        notices.append("Ignored an invalid action proposal.")
                    }
                }
            }

            let rendered = GroundedRenderer().render(
                claims: claims,
                queryPlan: queryPlan,
                bundle: bundle,
                followUps: proposed.followUps,
                tone: usedFallback ? nil : proposed.tone,
                notices: notices,
                usedDeterministicFallback: usedFallback
            )

            if let firstEntity = collected.entities.first {
                context.focusedRecordKeys = [.entity(type: firstEntity.entityType, id: firstEntity.gameID)]
            }
            context.recentTurnIDs.append(request.turnID)
            if context.recentTurnIDs.count > ConversationBounds.maxRecentTurns {
                context.recentTurnIDs.removeFirst(context.recentTurnIDs.count - ConversationBounds.maxRecentTurns)
            }
            context.lastEvidenceDigest = bundle.digest
            context.lastPackReleaseID = request.packIdentity.sourceCommitSHA

            return ValidatedAssistantTurn(
                text: rendered.text,
                cards: rendered.cards,
                note: rendered.note,
                followUps: rendered.chips,
                allowedActions: allowed,
                pendingActions: pendingActions,
                notices: notices,
                usedDeterministicFallback: usedFallback,
                packReleaseID: request.packIdentity.sourceCommitSHA,
                evidenceDigest: bundle.digest,
                refreshRequired: false
            )
        } catch is CancellationError {
            return cancelledTurn(request: request)
        } catch {
            return failClosed(
                request: request,
                notice: "Local data failed closed; Atlas did not substitute a network source. \(error.localizedDescription)"
            )
        }
    }

    private struct CollectedLocal {
        var entities: [Entity]
        var recipes: [Recipe]
        var content: [ContentRecord]
    }

    private func collectLocal(
        plan: AtlasQueryPlan,
        tools: LocalKnowledgeToolRegistry,
        catalog: any NMSCatalog
    ) async throws -> CollectedLocal {
        var entities: [Entity] = []
        if plan.shouldBrowseEntities, let entityType = plan.entityType {
            entities = try await catalog.entities(
                type: entityType,
                limit: ConversationBounds.answerEntityLimit,
                offset: 0
            )
            for entity in entities {
                _ = tools.database.ledger.issue(payload: .entity(entity), source: .packed)
            }
        } else if !plan.shouldBrowseRecipes {
            for query in plan.localSearchQueries {
                let output = try await tools.invoke(
                    LocalToolCall(
                        name: LocalToolName.searchEntities.rawValue,
                        query: query,
                        entityType: plan.entityType,
                        limit: ConversationBounds.answerEntityLimit
                    )
                )
                if output.status == .failed {
                    throw CatalogError.failure(output.notice ?? "search failed")
                }
                if case .entities(let rows) = output.payload {
                    entities.append(contentsOf: rows)
                }
                entities = uniqueEntities(entities)
                if entities.count >= ConversationBounds.answerEntityLimit { break }
            }
        }

        var recipes: [Recipe] = []
        if plan.shouldSearchRecipes, plan.goal != .uses {
            for query in plan.localSearchQueries {
                let output = try await tools.invoke(
                    LocalToolCall(
                        name: LocalToolName.searchRecipes.rawValue,
                        query: query,
                        recipeKind: plan.recipeKind,
                        limit: ConversationBounds.answerRecipeLimit
                    )
                )
                if output.status == .failed {
                    throw CatalogError.failure(output.notice ?? "search failed")
                }
                if case .recipes(let rows) = output.payload {
                    recipes.append(contentsOf: rows)
                }
                recipes = uniqueRecipes(recipes)
                if recipes.count >= ConversationBounds.answerRecipeLimit { break }
            }
        }

        if let first = entities.first {
            switch plan.goal {
            case .uses:
                let output = try await tools.invoke(
                    LocalToolCall(
                        name: LocalToolName.recipesUsing.rawValue,
                        entityType: first.entityType,
                        gameID: first.gameID,
                        limit: ConversationBounds.answerRecipeLimit
                    )
                )
                if case .recipes(let rows) = output.payload {
                    recipes.append(contentsOf: rows.filter { plan.matchesIntendedKind($0.recipeKind) })
                }
            case .recipe:
                let producing = try await tools.invoke(
                    LocalToolCall(
                        name: LocalToolName.recipesFor.rawValue,
                        entityType: first.entityType,
                        gameID: first.gameID,
                        limit: ConversationBounds.answerRecipeLimit
                    )
                )
                if case .recipes(let rows) = producing.payload {
                    recipes.append(contentsOf: rows.filter { plan.matchesIntendedKind($0.recipeKind) })
                }
                if plan.operation != nil {
                    let using = try await tools.invoke(
                        LocalToolCall(
                            name: LocalToolName.recipesUsing.rawValue,
                            entityType: first.entityType,
                            gameID: first.gameID,
                            limit: ConversationBounds.answerRecipeLimit
                        )
                    )
                    if case .recipes(let rows) = using.payload {
                        recipes.append(contentsOf: rows.filter { plan.matchesIntendedKind($0.recipeKind) })
                    }
                }
            case .lookup, .browseEntities, .browseRecipes:
                break
            }
        }

        recipes = uniqueRecipes(recipes)
        if recipes.isEmpty, plan.shouldBrowseRecipes {
            recipes = try await catalog.recipes(kind: plan.recipeKind, limit: ConversationBounds.answerRecipeLimit, offset: 0)
            for recipe in recipes {
                _ = tools.database.ledger.issue(payload: .recipe(recipe), source: .packed)
            }
        }

        if let quantity = RecipePlanIntent.quantity(from: plan.originalPrompt),
           let first = entities.first {
            _ = try await tools.invoke(
                LocalToolCall(
                    name: "plan_recipe",
                    entityType: first.entityType,
                    gameID: first.gameID,
                    quantity: quantity
                )
            )
        }

        var content: [ContentRecord] = []
        if !plan.shouldBrowseRecipes {
            for query in plan.localSearchQueries {
                let output = try await tools.invoke(
                    LocalToolCall(
                        name: LocalToolName.searchContent.rawValue,
                        query: query,
                        limit: ConversationBounds.answerContentLimit
                    )
                )
                if case .content(let rows) = output.payload {
                    content.append(contentsOf: rows)
                }
                content = uniqueContent(content)
                if content.count >= ConversationBounds.answerContentLimit { break }
            }
        }

        return CollectedLocal(entities: uniqueEntities(entities), recipes: recipes, content: content)
    }

    private func ingestAuthorizedExternal(
        _ external: ExternalEvidenceInput,
        policy: SourcePolicyDecision,
        queryPlan: AtlasQueryPlan,
        ledger: EvidenceLedger
    ) {
        if let proposed = external.proposedOutboundQuery,
           !OutboundQuery.matchesUserDerived(proposed, plan: queryPlan) {
            return
        }
        if policy.authorizesLive {
            for entity in external.liveEntities {
                _ = ledger.issue(payload: .entity(entity), source: .liveAtlas)
            }
        }
        if policy.authorizesWeb {
            for hit in external.webHits {
                _ = ledger.issue(payload: .web(hit), source: .communityWeb)
            }
        }
    }

    private func ensureSession(
        packReleaseID: String,
        capabilityBundleID: String,
        packIdentity: PackIdentity
    ) async {
        let packChanged = self.packReleaseID != packReleaseID
        let bundleChanged = self.capabilityBundleID != capabilityBundleID
        if packChanged || bundleChanged || ledger == nil {
            self.packReleaseID = packReleaseID
            self.capabilityBundleID = capabilityBundleID
            if packChanged || ledger == nil {
                ledger = EvidenceLedger(packIdentity: packIdentity)
                await pending.resetForPackChange()
                context.focusedRecordKeys = []
            }
        }
    }

    private func failClosed(request: ConversationTurnRequest, notice: String) -> ValidatedAssistantTurn {
        ValidatedAssistantTurn(
            text: "I could not read the installed Atlas pack.",
            cards: [],
            note: notice,
            followUps: [],
            allowedActions: [],
            pendingActions: [],
            notices: [notice],
            usedDeterministicFallback: true,
            packReleaseID: request.packIdentity.sourceCommitSHA,
            evidenceDigest: "",
            refreshRequired: false
        )
    }

    private func cancelledTurn(request: ConversationTurnRequest) -> ValidatedAssistantTurn {
        ValidatedAssistantTurn(
            text: "",
            cards: [],
            note: "Cancelled.",
            followUps: [],
            allowedActions: [],
            pendingActions: [],
            notices: ["Cancelled."],
            usedDeterministicFallback: true,
            packReleaseID: request.packIdentity.sourceCommitSHA,
            evidenceDigest: "",
            refreshRequired: false
        )
    }

    private func uniqueEntities(_ entities: [Entity]) -> [Entity] {
        var seen: Set<String> = []
        return entities.filter { seen.insert($0.id).inserted }
    }

    private func uniqueRecipes(_ recipes: [Recipe]) -> [Recipe] {
        var seen: Set<String> = []
        return recipes.filter { seen.insert($0.recipeID).inserted }
    }

    private func uniqueContent(_ content: [ContentRecord]) -> [ContentRecord] {
        var seen: Set<String> = []
        return content.filter { seen.insert($0.id).inserted }
    }
}
