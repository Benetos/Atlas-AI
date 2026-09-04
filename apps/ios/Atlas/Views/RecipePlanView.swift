import SwiftUI

struct RecipePlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var targetType: String
    var targetID: String
    var quantity: Int
    var artifactID: String?

    @State private var feature: RecipePlanModel

    init(targetType: String, targetID: String, quantity: Int, artifactID: String? = nil) {
        self.targetType = targetType
        self.targetID = targetID
        self.quantity = quantity
        self.artifactID = artifactID
        _feature = State(initialValue: RecipePlanModel(quantity: quantity, artifactID: artifactID))
    }

    var body: some View {
        LoadableStateView(
            state: feature.state,
            loadingTitle: "Calculating plan…",
            notFoundTitle: "Item not in this snapshot",
            notFoundSystemImage: "list.bullet.clipboard",
            failedTitle: "Could not calculate plan",
            onRefresh: { Task { await reload() } }
        ) { plan in
            List {
                if let error = feature.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                    }
                }
                if let diff = feature.recomputeDiff, diff.hasChanges {
                    Section("Refresh required") {
                        Text(recomputeSummary(diff))
                            .foregroundStyle(.secondary)
                        Button("Create new revision") {
                            Task {
                                await feature.confirmRecompute(
                                    identifiers: model.services.identifiers,
                                    clock: model.services.clock,
                                    saved: model.saved
                                )
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    if let preview = feature.recomputePreview {
                        Section("New revision preview") {
                            ForEach(Array(preview.checklist.enumerated()), id: \.offset) { _, line in
                                Text("\(line.quantity)× \(line.title)")
                            }
                        }
                    }
                }
                Section("Target") {
                    Stepper(value: $feature.quantity, in: ConversationBounds.quantityRange) {
                        Text("Quantity \(feature.quantity)")
                    }
                    .frame(minHeight: 44)
                    .disabled(feature.isFrozen)
                    .onChange(of: feature.quantity) {
                        guard !feature.isFrozen else { return }
                        Task { await reload() }
                    }
                    SourceBadge(
                        presentation: SourcePresentation(
                            kind: .calculated,
                            releaseLabel: plan.derivedEvidence.provenanceLabel
                        ),
                        expanded: true
                    )
                    if plan.truncated {
                        Text("Expansion stopped at a planner bound.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !plan.notices.isEmpty {
                    Section("Notes") {
                        ForEach(Array(plan.notices.enumerated()), id: \.offset) { _, notice in
                            Text(notice)
                        }
                    }
                }
                if !plan.cycles.isEmpty {
                    Section("Cycles") {
                        ForEach(Array(plan.cycles.enumerated()), id: \.offset) { _, cycle in
                            Text(cycle.path.joined(separator: " → "))
                                .font(.footnote)
                        }
                    }
                }
                if !feature.isFrozen,
                   !plan.alternatives.filter({ $0.recipes.count > 1 }).isEmpty {
                    Section("Alternate routes") {
                        ForEach(plan.alternatives.filter { $0.recipes.count > 1 }) { group in
                            Picker(group.title, selection: selectionBinding(group.nodeID)) {
                                ForEach(group.recipes) { recipe in
                                    Text("\(recipe.title) (\(recipe.recipeKind))")
                                        .tag(recipe.recipeID)
                                }
                            }
                            .frame(minHeight: 44)
                            .disabled(feature.isFrozen)
                        }
                    }
                }
                if !feature.isFrozen {
                    Section("Dependencies") {
                        PlanTreeRows(node: plan.root)
                    }
                }
                Section(feature.isFrozen ? "Saved checklist" : "Checklist") {
                    checklist(for: plan.checklist)
                }
            }
            .toolbar {
                Button {
                    Task {
                        await feature.save(
                            identifiers: model.services.identifiers,
                            clock: model.services.clock,
                            saved: model.saved
                        )
                    }
                } label: {
                    Image(systemName: feature.savedRevision == nil ? "square.and.arrow.down" : "square.and.arrow.down.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(feature.savedRevision == nil ? "Save plan" : "Update saved plan")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(targetType):\(targetID):\(artifactID ?? ""):\(model.generationID)") {
            await reload()
        }
    }

    private var title: String {
        if case .loaded(let plan) = feature.state {
            return "\(plan.quantity)× \(plan.targetTitle)"
        }
        return "Plan"
    }

    @ViewBuilder
    private func checklist(for lines: [ChecklistLine]) -> some View {
        if lines.isEmpty {
            Text("Nothing to gather.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(lines) { line in
                checklistRow(line)
            }
        }
    }

    @ViewBuilder
    private func checklistRow(_ line: ChecklistLine) -> some View {
        let check = Button {
            Task {
                await feature.toggleProgress(
                    lineID: line.id,
                    clock: model.services.clock,
                    saved: model.saved
                )
            }
        } label: {
            HStack {
                Image(systemName: feature.progress[line.id] == true ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading) {
                    Text("\(line.quantity)× \(line.title)")
                    if line.isCycle {
                        Text("Cycle").font(.caption).foregroundStyle(.secondary)
                    }
                    if line.isTruncated {
                        Text("Truncated").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)

        let link = AtlasOpenLink(
            destination: .entity(type: line.entityType, id: line.gameID),
            section: router.selectedSection
        ) {
            Image(systemName: "chevron.forward")
                .frame(minWidth: 44, minHeight: 44)
        }

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                check
                link
            }
        } else {
            HStack {
                check
                link
            }
        }
    }

    private func selectionBinding(_ nodeID: String) -> Binding<String> {
        Binding(
            get: { feature.selections[nodeID] ?? "" },
            set: { recipeID in
                Task {
                    guard !feature.isFrozen, let catalog = model.catalog else { return }
                    await feature.selectAlternative(
                        nodeID: nodeID,
                        recipeID: recipeID,
                        type: targetType,
                        id: targetID,
                        catalog: catalog,
                        packIdentity: model.packIdentity,
                        saved: model.saved
                    )
                }
            }
        )
    }

    private func recomputeSummary(_ diff: RecipePlanRecomputeDiff) -> String {
        var parts: [String] = []
        if diff.packChanged { parts.append("The installed pack changed.") }
        if diff.engineChanged { parts.append("The planner engine changed.") }
        if !diff.changedQuantities.isEmpty { parts.append("Some quantities changed.") }
        if !diff.missingLineIDs.isEmpty { parts.append("Some ingredients disappeared.") }
        if !diff.newLineIDs.isEmpty { parts.append("New ingredients appeared.") }
        if diff.recipeMissing { parts.append("A selected recipe is missing.") }
        parts.append("The current revision is unchanged until you confirm.")
        return parts.joined(separator: " ")
    }

    @MainActor
    private func reload() async {
        guard let catalog = model.catalog else {
            feature.state = .failed(CatalogError.unavailable.localizedDescription)
            return
        }
        await feature.load(
            type: targetType,
            id: targetID,
            catalog: catalog,
            packIdentity: model.packIdentity,
            saved: model.saved
        )
    }
}

private struct PlanTreeRows: View {
    var node: PlanNode

    var body: some View {
        if let children = node.outlineChildren {
            DisclosureGroup {
                ForEach(children) { child in
                    PlanTreeRows(node: child)
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack {
            Text(label)
            Spacer()
            Text(node.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        if let crafts = node.crafts {
            return "\(node.quantity)× \(node.title) (\(crafts) crafts)"
        }
        return "\(node.quantity)× \(node.title)"
    }
}
