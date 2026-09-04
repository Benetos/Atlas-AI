import SwiftUI

@Observable
@MainActor
final class AtlasConversationModel {
    var draft = ""
    var messages: [AtlasMessage] = []
    var busy = false
    var confirmWeb = false
    var pendingWebPrompt: String?
    var narrationTask: Task<Void, Never>?
    var sendGeneration: UInt64 = 0
}

struct AtlasView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasConversationModel.self) private var conversation

    private let chips = [
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
            Button("Allow internet search") {
                model.settings.webSearchEnabled = true
                model.settings.webSearchConfirmed = true
                let prompt = conversation.pendingWebPrompt ?? "Search the web for current No Man's Sky expedition"
                conversation.pendingWebPrompt = nil
                Task { await send(prompt) }
            }
            Button("Cancel", role: .cancel) {
                conversation.pendingWebPrompt = nil
            }
        }
        .onChange(of: model.generationID) {
            cancelNarration()
            conversation.sendGeneration += 1
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
    private func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let store = model.store else { return }
        let plan = await model.services.planner.plan(prompt: prompt)
        if plan.requestsWeb && !model.settings.webSearchConfirmed {
            conversation.pendingWebPrompt = prompt
            conversation.confirmWeb = true
            return
        }
        if plan.requestsWeb && !model.settings.webSearchEnabled {
            model.settings.webSearchEnabled = true
        }
        if plan.requestsWeb || plan.requestsLive {
            model.services.network.record("atlas.external-source-intent")
        }
        cancelNarration()
        conversation.sendGeneration += 1
        let token = conversation.sendGeneration
        conversation.draft = ""
        conversation.messages.append(AtlasMessage(role: .user, text: prompt))
        conversation.busy = true
        defer { conversation.busy = false }
        let controller = AtlasSessionController(store: store, settings: model.settings)
        var reply = await controller.reply(to: prompt)
        guard token == conversation.sendGeneration else { return }
        if model.services.modelAvailability.current == .available,
           reply.cards.contains(where: { card in
               if case .web = card { return false }
               return true
           }) {
            switch await boundedNarration(
                controller: controller,
                prompt: prompt,
                grounded: reply
            ) {
            case .completed(let text):
                reply.text = text
            case .timedOut:
                reply.note = addingNote(
                    "On-device narration exceeded eight seconds. Showing the verified database answer.",
                    to: reply.note
                )
            case .failed:
                reply.note = addingNote(
                    "On-device narration was unavailable. Showing the verified database answer.",
                    to: reply.note
                )
            }
        }
        guard token == conversation.sendGeneration else { return }
        let assistant = AtlasMessage(
            role: .assistant,
            text: reply.text,
            cards: reply.cards,
            note: reply.note
        )
        conversation.messages.append(assistant)
        if case .entity(let entity) = reply.cards.first {
            await model.saved.remember(model.bookmark(for: entity))
        }
    }

    @MainActor
    private func boundedNarration(
        controller: AtlasSessionController,
        prompt: String,
        grounded: AtlasReply
    ) async -> NarrationResult {
        let resultBox = NarrationResultBox()
        conversation.narrationTask = Task { @MainActor in
            let value = await controller.narration(to: prompt, grounded: grounded)
            await resultBox.finish(value)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            switch await resultBox.poll() {
            case .pending:
                try? await Task.sleep(for: .milliseconds(50))
            case .finished(let value):
                conversation.narrationTask = nil
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty
                else { return .failed }
                return .completed(value)
            }
        }

        conversation.narrationTask?.cancel()
        conversation.narrationTask = nil
        return .timedOut
    }

    @MainActor
    private func cancelNarration() {
        conversation.narrationTask?.cancel()
        conversation.narrationTask = nil
    }

    private func addingNote(_ newNote: String, to existing: String?) -> String {
        [existing, newNote].compactMap { $0 }.joined(separator: " ")
    }
}

private enum NarrationResult {
    case completed(String)
    case failed
    case timedOut
}

private enum NarrationPollResult: Sendable {
    case pending
    case finished(String?)
}

private actor NarrationResultBox {
    private var result: NarrationPollResult = .pending

    func finish(_ value: String?) {
        guard case .pending = result else { return }
        result = .finished(value)
    }

    func poll() -> NarrationPollResult {
        result
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
