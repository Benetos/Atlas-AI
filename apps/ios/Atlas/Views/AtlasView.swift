import SwiftUI

struct AtlasView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var messages: [AtlasMessage] = []
    @State private var busy = false
    @State private var confirmWeb = false

    private let chips = [
        "How do I cook food?",
        "What is Ferrite Dust for?",
        "Circuit Board recipe",
        "Refining Carbon",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if messages.isEmpty {
                                emptyState
                            }
                            ForEach(messages) { message in
                                messageBlock(message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                composer
            }
            .navigationTitle("Atlas")
            .navigationDestination(for: AtlasRoute.self) { route in
                switch route {
                case .entity(let type, let id):
                    EntityDetailView(entityType: type, gameID: id)
                case .recipe(let id):
                    RecipeDetailView(recipeID: id)
                }
            }
            .confirmationDialog(
                "Search the internet? This query will leave the device.",
                isPresented: $confirmWeb,
                titleVisibility: .visible
            ) {
                Button("Allow internet search") {
                    model.settings.webSearchEnabled = true
                    model.settings.webSearchConfirmed = true
                    Task { await send("Search the web for current No Man's Sky expedition") }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
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
                        confirmWeb = true
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
        if model.settings.liveAtlasEnabled {
            values.append("Search live Atlas")
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
            NavigationLink(value: AtlasRoute.entity(type: entity.entityType, id: entity.gameID)) {
                EntityCardView(entity: entity)
            }
            .buttonStyle(.plain)
        case .recipe(let recipe):
            NavigationLink(value: AtlasRoute.recipe(id: recipe.recipeID)) {
                RecipeCardView(recipe: recipe)
            }
            .buttonStyle(.plain)
        case .content(let record):
            ContentCardView(record: record)
        case .web(let hit):
            Link(destination: hit.url) {
                WebCardView(hit: hit)
            }
            .buttonStyle(.plain)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Atlas…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(busy)
            Button {
                Task { await send(draft) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    @MainActor
    private func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let store = model.store else { return }
        draft = ""
        messages.append(AtlasMessage(role: .user, text: prompt))
        busy = true
        defer { busy = false }
        let controller = AtlasSessionController(store: store, settings: model.settings)
        let reply = await controller.reply(to: prompt)
        messages.append(
            AtlasMessage(role: .assistant, text: reply.text, cards: reply.cards, note: reply.note)
        )
        if case .entity(let entity) = reply.cards.first {
            model.saved.remember(
                SavedItem(
                    kind: .entity,
                    entityType: entity.entityType,
                    gameID: entity.gameID,
                    recipeID: nil,
                    title: entity.title,
                    savedAt: Date()
                )
            )
        }
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
            }
        }
    }
}
