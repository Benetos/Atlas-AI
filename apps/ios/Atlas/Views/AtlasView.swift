import SwiftUI

@Observable
@MainActor
final class AtlasConversationModel {
    var draft = ""
    var messages: [AtlasMessage] = []
    var busy = false
    var confirmWeb = false
    var pendingWebPrompt: String?
    var pendingTurnID: String?
    var pendingReceipts: [ExternalConsentReceipt] = []
    var narrationTask: Task<Void, Never>?
    var sendGeneration: UInt64 = 0
    let engine = AtlasConversationEngine()
}

struct AtlasView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasConversationModel.self) private var conversation
    @Environment(AtlasRouter.self) private var router

    private let chips = [
        "I need 12 Circuit Boards",
        "How do I cook food?",
        "What is Ferrite Dust for?",
        "Circuit Board recipe",
        "Refining Carbon",
    ]

    var body: some View {
        @Bindable var conversation = conversation
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if conversation.messages.isEmpty {
                            emptyState
                        }
                        ForEach(conversation.messages) { message in
                            messageBlock(message)
                                .id(message.id)
                        }
                        if conversation.busy {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Building a grounded answer…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation.messages.count) {
                    if let last = conversation.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            composer
        }
        .navigationTitle("Atlas")
        .confirmationDialog(
            "Search the internet? This query will leave the device.",
            isPresented: $conversation.confirmWeb,
            titleVisibility: .visible
        ) {
            Button("Allow this search") {
                model.settings.webSearchEnabled = true
                model.settings.webSearchConfirmed = true
                let prompt = conversation.pendingWebPrompt ?? "Search the web for current No Man's Sky expedition"
                let turnID = conversation.pendingTurnID ?? model.services.identifiers.makeID()
                if let query = try? OutboundQuery.derive(from: AtlasQueryPlan(prompt: prompt)) {
                    let now = model.services.clock.now()
                    conversation.pendingReceipts.append(
                        ExternalConsentReceipt(
                            id: model.services.identifiers.makeID(),
                            source: .web,
                            normalizedOutboundQuery: query,
                            originatingTurnID: turnID,
                            issuedAt: now,
                            expiresAt: now.addingTimeInterval(ConversationBounds.consentTTL),
                            consumed: false
                        )
                    )
                }
                conversation.pendingWebPrompt = nil
                Task { await send(prompt, turnID: turnID) }
            }
            Button("Cancel", role: .cancel) {
                conversation.pendingWebPrompt = nil
                conversation.pendingTurnID = nil
            }
        }
        .onChange(of: model.generationID) {
            cancelNarration()
            conversation.sendGeneration += 1
            if let identity = model.packIdentity {
                Task { await conversation.engine.handlePackChange(identity) }
            }
        }
        .onDisappear {
            cancelNarration()
        }
    }

    private var packedProvenance: SourcePresentation {
        .packed(model.packIdentity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Atlas about items, crafting, refining, or cooking. Answers come from the pinned local snapshot.")
                .foregroundStyle(.secondary)
            FlowChips(titles: chipTitles) { title in
                if title == "Search the web" {
                    if model.settings.webSearchConfirmed {
                        Task { await send("Search the web for current No Man's Sky expedition") }
                    } else {
                        conversation.pendingWebPrompt = "Search the web for current No Man's Sky expedition"
                        conversation.confirmWeb = true
                    }
                } else {
                    Task { await send(title) }
                }
            }
        }
    }

    private var chipTitles: [String] {
        var values = chips
        if model.settings.webSearchEnabled || !model.settings.webSearchConfirmed {
            values.append("Search the web")
        }
        return values
    }

    private func messageBlock(_ message: AtlasMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            Text(message.text)
                .padding(12)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            if let note = message.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if message.refreshRequired {
                Text("Refresh required")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(message.followUps) { chip in
                Button(chip.label) {
                    activate(chip)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
            ForEach(message.pendingActions) { pending in
                VStack(alignment: .leading, spacing: 8) {
                    Text(pending.exactEffectDescription)
                        .font(.subheadline)
                    HStack {
                        Button("Confirm") {
                            Task { await confirm(pending) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Decline", role: .cancel) {
                            Task { await decline(pending) }
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            ForEach(message.cards) { card in
                cardView(card)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func cardView(_ card: AtlasCard) -> some View {
        switch card {
        case .entity(let entity):
            AtlasOpenLink(
                destination: .entity(type: entity.entityType, id: entity.gameID),
                section: .atlas,
                replacesPath: true
            ) {
                EntityCardView(entity: entity, provenance: packedProvenance)
            }
        case .recipe(let recipe):
            AtlasOpenLink(destination: .recipe(id: recipe.recipeID), section: .atlas, replacesPath: true) {
                RecipeCardView(recipe: recipe, provenance: packedProvenance)
            }
        case .content(let record):
            AtlasOpenLink(
                destination: .content(
                    dataset: record.dataset,
                    id: record.externalID,
                    sourceOrdinal: record.sourceOrdinal
                ),
                section: .atlas,
                replacesPath: true
            ) {
                ContentCardView(record: record, provenance: packedProvenance)
            }
        case .web(let hit):
            Link(destination: hit.url) {
                WebCardView(hit: hit)
            }
            .buttonStyle(.plain)
        }
    }

    private var composer: some View {
        @Bindable var conversation = conversation
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Atlas…", text: $conversation.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(conversation.busy)
            Button {
                Task { await send(conversation.draft) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(conversation.busy || conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    @MainActor
    private func send(_ text: String, turnID: String? = nil) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let catalog = model.catalog, let packIdentity = model.packIdentity else { return }
        let plan = await model.services.planner.plan(prompt: prompt)
        let resolvedTurnID = turnID
            ?? conversation.pendingTurnID
            ?? model.services.identifiers.makeID()
        let snapshot = SourcePolicySnapshot(
            settings: model.settings,
            packAvailable: true
        )
        let policy = SourcePolicyDecision.decide(
            plan: plan,
            snapshot: snapshot,
            receipts: conversation.pendingReceipts,
            turnID: resolvedTurnID,
            now: model.services.clock.now()
        )
        if plan.requestsWeb && (policy.requiresWebConsent || !model.settings.webSearchConfirmed) {
            conversation.pendingWebPrompt = prompt
            conversation.pendingTurnID = resolvedTurnID
            conversation.confirmWeb = true
            return
        }

        cancelNarration()
        conversation.sendGeneration += 1
        let token = conversation.sendGeneration
        conversation.draft = ""
        conversation.pendingTurnID = nil
        conversation.messages.append(AtlasMessage(role: .user, text: prompt))
        conversation.busy = true
        defer { conversation.busy = false }

        var external = ExternalEvidenceInput.empty
        var fetchNotes: [String] = []
        if policy.authorizesLive, let query = policy.outboundQuery {
            model.services.network.record("atlas.live-fetch")
            consumeReceipt(source: .liveAtlas, turnID: resolvedTurnID)
            do {
                external.liveEntities = try await LiveAtlasClient(settings: model.settings)
                    .searchEntities(query: query, type: nil)
            } catch {
                fetchNotes.append("Live Atlas unavailable. Showing the installed pack only.")
            }
        }
        if policy.authorizesWeb, let query = policy.outboundQuery {
            model.services.network.record("atlas.web-fetch")
            consumeReceipt(source: .web, turnID: resolvedTurnID)
            do {
                external.webHits = try await WebSearchClient().search(query: query)
            } catch {
                fetchNotes.append("Web search unavailable.")
            }
        }

        let request = ConversationTurnRequest(
            prompt: prompt,
            turnID: resolvedTurnID,
            generation: token,
            packIdentity: packIdentity,
            catalog: catalog,
            snapshot: snapshot,
            receipts: conversation.pendingReceipts,
            external: external,
            flags: model.services.generativeFlags,
            modelAvailability: model.services.modelAvailability.current,
            identifiers: model.services.identifiers,
            clock: model.services.clock
        )
        let turn = await conversation.engine.reply(
            request,
            queryPlanner: model.services.planner,
            proposedPlanner: model.services.proposedPlanner
        )
        guard token == conversation.sendGeneration else { return }

        var note = turn.note
        if !fetchNotes.isEmpty {
            note = [note].compactMap { $0 }.joined(separator: " ")
            note = [note, fetchNotes.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
        }
        let assistant = AtlasMessage(
            role: .assistant,
            text: turn.text,
            cards: turn.cards,
            note: note,
            followUps: turn.followUps,
            pendingActions: turn.pendingActions,
            refreshRequired: turn.refreshRequired,
            packReleaseID: turn.packReleaseID
        )
        conversation.messages.append(assistant)
    }

    @MainActor
    private func activate(_ chip: ClarificationChip) {
        switch chip.intent {
        case .clarifyRecord(let keys):
            if let first = keys.first, let destination = first.destination {
                router.select(destination, in: .atlas)
            }
        case .requestExternalSource(.web, let query):
            conversation.pendingWebPrompt = "Search the web for \(query)"
            conversation.pendingTurnID = model.services.identifiers.makeID()
            conversation.confirmWeb = true
        case .requestExternalSource(.liveAtlas, let query):
            Task { await send("Search live Atlas for \(query)") }
        case .open(let key):
            if let destination = key.destination {
                router.select(destination, in: .atlas)
            }
        case .usesFor(_, let id):
            Task { await send("What is \(id) used in?") }
        case .recipesFor(_, let id):
            Task { await send("\(id) recipe") }
        case .plan(let type, let id, let quantity):
            router.select(
                .recipePlan(type: type, id: id, quantity: quantity),
                in: .atlas
            )
        }
    }

    @MainActor
    private func confirm(_ pending: PendingAction) async {
        do {
            let action = try await conversation.engine.confirm(
                nonce: pending.nonce,
                packReleaseID: model.packIdentity?.sourceCommitSHA ?? pending.packReleaseID,
                evidenceDigest: pending.evidenceDigest,
                now: model.services.clock.now()
            )
            await applyImmediate(ResolvedAction(
                action: action,
                evidenceIDs: pending.evidenceIDs,
                evidenceDigest: pending.evidenceDigest,
                packReleaseID: pending.packReleaseID,
                recordKeys: pending.resolved.recordKeys
            ))
        } catch {
            conversation.messages.append(
                AtlasMessage(
                    role: .assistant,
                    text: error.localizedDescription,
                    refreshRequired: (error as? PendingActionExecutionError) == .packMismatch
                )
            )
        }
    }

    @MainActor
    private func decline(_ pending: PendingAction) async {
        try? await conversation.engine.decline(nonce: pending.nonce)
    }

    @MainActor
    private func applyImmediate(_ resolved: ResolvedAction) async {
        switch resolved.action {
        case .open(let destination), .filter(let destination):
            router.select(destination, in: .atlas)
        case .plan(let type, let id, let quantity):
            router.select(
                .recipePlan(type: type, id: id, quantity: quantity),
                in: .atlas
            )
        case .save(let key):
            guard let catalog = model.catalog else { return }
            switch key {
            case .entity(let type, let id):
                if let entity = try? await catalog.entity(type: type, id: id) {
                    await model.saved.remember(model.bookmark(for: entity))
                }
            case .recipe(let id):
                if let recipe = try? await catalog.recipe(id: id) {
                    await model.saved.remember(model.bookmark(for: recipe))
                }
            default:
                break
            }
        case .requestExternalSource, .compare, .guide, .configure, .export:
            break
        }
    }

    private func consumeReceipt(source: ExternalSourceKind, turnID: String) {
        if let index = conversation.pendingReceipts.firstIndex(where: {
            $0.source == source && $0.originatingTurnID == turnID && !$0.consumed
        }) {
            conversation.pendingReceipts[index].consume()
        }
    }

    @MainActor
    private func cancelNarration() {
        conversation.narrationTask?.cancel()
        conversation.narrationTask = nil
    }
}

struct FlowChips: View {
    var titles: [String]
    var action: (String) -> Void

    var body: some View {
        FlexibleChipWrap(titles: titles, action: action)
    }
}

private struct FlexibleChipWrap: View {
    var titles: [String]
    var action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(titles, id: \.self) { title in
                Button(title) { action(title) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
    }
}
