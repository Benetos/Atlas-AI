import SwiftUI

struct SpecialistCollectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasRouter.self) private var router
    var feature: SpecialistFeature
    var usesLibraryTitle: Bool = false
    var route: SpecialistRoute? = nil

    @State private var session: SpecialistCollectionModel

    init(feature: SpecialistFeature, usesLibraryTitle: Bool = false, route: SpecialistRoute? = nil) {
        self.feature = feature
        self.usesLibraryTitle = usesLibraryTitle
        self.route = route
        _session = State(initialValue: SpecialistCollectionModel(feature: feature, route: route))
    }

    var body: some View {
        @Bindable var session = session
        List {
            filterSection
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.items) { item in
                row(item)
            }
            if session.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if session.items.isEmpty && session.error == nil {
                ContentUnavailableView(
                    "No \(feature.title)",
                    systemImage: feature.systemImage,
                    description: Text("Nothing in this snapshot matches the current filters.")
                )
            } else if session.hasMore {
                Button("Load more") {
                    Task { await load(reset: false) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(usesLibraryTitle ? "Library" : feature.title)
        .toolbar {
            if feature.supportsCompare {
                Button("Compare") {
                    Task {
                        guard let catalog else { return }
                        await session.openCompare(catalog: catalog)
                    }
                }
                .disabled(session.compareIDs.count != 2 || catalog == nil)
            }
        }
        .sheet(isPresented: $session.showingCompare) {
            NavigationStack {
                SpecialistCompareView(details: session.compareDetails)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { session.showingCompare = false }
                        }
                    }
            }
        }
        .task(id: "\(session.filterTaskID):\(model.generationID)") {
            await load(reset: true)
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        @Bindable var session = session
        Section("Filters") {
            TextField("Search \(feature.title.lowercased())", text: $session.search)
            if !session.options.times.isEmpty {
                optionalPicker("Time", selection: $session.timeOfDay, values: session.options.times)
            }
            if !session.options.biomes.isEmpty {
                optionalPicker("Biome", selection: $session.biome, values: session.options.biomes)
            }
            if !session.options.sizes.isEmpty {
                optionalPicker("Size", selection: $session.size, values: session.options.sizes)
            }
            if !session.options.qualities.isEmpty {
                optionalPicker("Quality", selection: $session.quality, values: session.options.qualities)
            }
            if feature == .fish {
                Picker("Storm", selection: stormBinding) {
                    Text("Any").tag(Optional<Bool>.none)
                    Text("Needs storm").tag(Optional.some(true))
                    Text("No storm required").tag(Optional.some(false))
                }
            }
            if !session.options.usedFor.isEmpty {
                optionalPicker("Used for", selection: $session.usedFor, values: session.options.usedFor)
            }
            if !session.options.shipTypes.isEmpty {
                optionalPicker("Type", selection: $session.shipType, values: session.options.shipTypes)
            }
            if !session.options.categories.isEmpty {
                optionalPicker("Category", selection: $session.category, values: session.options.categories)
            }
            if feature.hidesDisabledByDefault {
                Toggle("Show not enabled", isOn: $session.includeNotEnabled)
            }
        }
    }

    private var stormBinding: Binding<Bool?> {
        Binding(
            get: { session.needsStorm },
            set: { session.needsStorm = $0 }
        )
    }

    private func optionalPicker(
        _ title: String,
        selection: Binding<String?>,
        values: [String]
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(Optional<String>.none)
            ForEach(values, id: \.self) { value in
                Text(value).tag(Optional(value))
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SpecialistSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AtlasOpenLink(
                destination: item.destination,
                section: router.selectedSection,
                replacesPath: true
            ) {
                SpecialistCardView(item: item)
            }
            if feature.supportsCompare {
                Button(session.isComparing(item) ? "Remove from compare" : "Add to compare") {
                    session.toggleCompare(item)
                }
                .font(.caption)
            }
        }
    }

    private var catalog: (any NMSCatalog)? { model.catalog }

    @MainActor
    private func load(reset: Bool) async {
        guard let catalog else { return }
        await session.load(catalog: catalog, reset: reset)
    }
}

struct SpecialistCardView: View {
    var item: SpecialistSummary
    var provenance: SourcePresentation?

    var body: some View {
        AtlasCardShell {
            HStack(alignment: .top, spacing: 12) {
                PackedIcon(
                    sourcePath: item.iconSourcePath,
                    fallbackEntityType: item.feature.placeholderEntityType
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !item.badges.isEmpty {
                        Text(item.badges.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let provenance {
                        SourceBadge(presentation: provenance)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct SpecialistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasRouter.self) private var router
    var feature: SpecialistFeature
    var externalID: String
    var sourceOrdinal: Int

    @State private var detail = SpecialistDetailModel()

    var body: some View {
        LoadableStateView(
            state: detail.state,
            loadingTitle: "Loading \(feature.title.lowercased())…",
            notFoundTitle: "\(feature.title) not in this snapshot",
            notFoundSystemImage: feature.systemImage,
            failedTitle: "Could not load \(feature.title.lowercased())",
            onRefresh: { Task { await load() } }
        ) { content in
            List {
                Section {
                    HStack(spacing: 12) {
                        PackedIcon(
                            sourcePath: content.summary.iconSourcePath,
                            fallbackEntityType: feature.placeholderEntityType
                        )
                        VStack(alignment: .leading) {
                            Text(content.summary.title).font(.title2.bold())
                            Text(feature.title).foregroundStyle(.secondary)
                            SourceBadge(presentation: .packed(model.packIdentity), expanded: true)
                        }
                    }
                    ForEach(content.fields) { field in
                        if field.key != "description" {
                            LabeledContent(field.label, value: field.value)
                        }
                    }
                }
                if let description = content.fields.first(where: { $0.key == "description" }) {
                    Section("Description") { Text(description.value) }
                }
                if !content.biomes.isEmpty {
                    Section("Biomes") {
                        ForEach(content.biomes, id: \.self) { biome in
                            Text(biome)
                        }
                    }
                }
                if !content.categories.isEmpty {
                    Section("Categories") {
                        ForEach(content.categories, id: \.self) { category in
                            Text(category)
                        }
                    }
                }
                if !content.rewardSources.isEmpty {
                    Section("Sources") {
                        ForEach(content.rewardSources, id: \.self) { source in
                            Text(source)
                        }
                    }
                }
                if !content.requirements.isEmpty {
                    Section(feature.supportsChecklist ? "Checklist" : "Requirements") {
                        ForEach(content.requirements) { requirement in
                            requirementRow(requirement)
                        }
                    }
                }
                if !content.storyPages.isEmpty {
                    ForEach(content.storyPages) { page in
                        Section(page.title ?? "Page \(page.position + 1)") {
                            ForEach(page.entries) { entry in
                                storyRow(entry)
                            }
                        }
                    }
                }
                if !content.extraFields.isEmpty {
                    Section("Additional packed fields") {
                        ForEach(content.extraFields) { field in
                            LabeledContent(field.label, value: field.value)
                        }
                    }
                }
                Section {
                    DisclosureGroup("Raw source record") {
                        ScrollView(.horizontal) {
                            Text(content.prettyPayload)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
        .navigationTitle(loadedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(feature.dataset):\(externalID):\(sourceOrdinal):\(model.generationID)") {
            await load()
        }
    }

    @ViewBuilder
    private func requirementRow(_ requirement: SpecialistRequirement) -> some View {
        HStack {
            if feature.supportsChecklist {
                Button {
                    if detail.checkedRequirementIDs.contains(requirement.id) {
                        detail.checkedRequirementIDs.remove(requirement.id)
                    } else {
                        detail.checkedRequirementIDs.insert(requirement.id)
                    }
                } label: {
                    Image(
                        systemName: detail.checkedRequirementIDs.contains(requirement.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    detail.checkedRequirementIDs.contains(requirement.id)
                        ? "Mark \(requirement.label) incomplete"
                        : "Mark \(requirement.label) complete"
                )
            }
            if let type = requirement.entityType, let gameID = requirement.gameID {
                AtlasOpenLink(
                    destination: .entity(type: type, id: gameID),
                    section: router.selectedSection
                ) {
                    HStack {
                        Text(requirement.label)
                        Spacer()
                        if let amount = requirement.amount {
                            Text(amount).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack {
                    Text(requirement.label)
                    Spacer()
                    if let amount = requirement.amount {
                        Text(amount).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func storyRow(_ entry: SpecialistStoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    if detail.checkedStoryIDs.contains(entry.id) {
                        detail.checkedStoryIDs.remove(entry.id)
                    } else {
                        detail.checkedStoryIDs.insert(entry.id)
                    }
                } label: {
                    Image(
                        systemName: detail.checkedStoryIDs.contains(entry.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                if let title = entry.title {
                    Text(title).font(.headline)
                }
            }
            if let body = entry.body, !body.isEmpty {
                Text(body)
            }
        }
    }

    private var loadedTitle: String {
        if case .loaded(let content) = detail.state {
            return content.summary.title
        }
        return feature.title
    }

    @MainActor
    private func load() async {
        guard let catalog = model.catalog else {
            detail.state = .failed(CatalogError.unavailable.localizedDescription)
            return
        }
        await detail.load(
            feature: feature,
            id: externalID,
            sourceOrdinal: sourceOrdinal,
            catalog: catalog
        )
    }
}

struct SpecialistCompareView: View {
    var details: [SpecialistDetail]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(details) { detail in
                    VStack(alignment: .leading, spacing: 12) {
                        PackedIcon(
                            sourcePath: detail.summary.iconSourcePath,
                            fallbackEntityType: detail.summary.feature.placeholderEntityType
                        )
                        Text(detail.summary.title).font(.headline)
                        ForEach(detail.fields) { field in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(field.value)
                            }
                        }
                        if !detail.biomes.isEmpty {
                            LabeledContent("Biomes", value: detail.biomes.joined(separator: ", "))
                        }
                    }
                    .frame(minWidth: 220, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding()
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
    }
}
