import SwiftUI

struct RecipePlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(AtlasRouter.self) private var router

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
                }
                Section("Target") {
                    Stepper(value: $feature.quantity, in: ConversationBounds.quantityRange) {
                        Text("Quantity \(feature.quantity)")
                    }
                    .frame(minHeight: 44)
                    .disabled(feature.recomputeDiff?.hasChanges == true)
                    .onChange(of: feature.quantity) {
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
                        ForEach(plan.notices, id: \.self) { notice in
                            Text(notice)
                        }
                    }
                }
                if !plan.cycles.isEmpty {
                    Section("Cycles") {
                        ForEach(plan.cycles, id: \.path) { cycle in
                            Text(cycle.path.joined(separator: " → "))
                                .font(.footnote)
                        }
                    }
                }
                if !plan.alternatives.filter({ $0.recipes.count > 1 }).isEmpty {
                    Section("Alternate routes") {
                        ForEach(plan.alternatives.filter { $0.recipes.count > 1 }) { group in
                            Picker(group.nodeID, selection: selectionBinding(group.nodeID)) {
                                ForEach(group.recipes) { recipe in
                                    Text("\(recipe.title) (\(recipe.recipeKind))")
                                        .tag(recipe.recipeID)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
                Section("Dependencies") {
                    PlanTreeRows(node: plan.root, depth: 0)
                }
                Section("Checklist") {
                    if plan.checklist.isEmpty {
                        Text("Nothing to gather.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(plan.checklist) { line in
                            HStack {
                                Button {
                                    feature.toggleProgress(lineID: line.id)
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
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(minHeight: 44)
                                AtlasOpenLink(
                                    destination: .entity(type: line.entityType, id: line.gameID),
                                    section: router.selectedSection
                                ) {
                                    Image(systemName: "chevron.forward")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                            }
                        }
                    }
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

    private func selectionBinding(_ nodeID: String) -> Binding<String> {
        Binding(
            get: { feature.selections[nodeID] ?? "" },
            set: { recipeID in
                Task {
                    guard let catalog = model.catalog else { return }
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
    var depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(repeating: "  ", count: depth) + label)
                Spacer()
                Text(node.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                PlanTreeRows(node: child, depth: depth + 1)
            }
        }
    }

    private var label: String {
        if let crafts = node.crafts {
            return "\(node.quantity)× \(node.title) (\(crafts) crafts)"
        }
        return "\(node.quantity)× \(node.title)"
    }
}
