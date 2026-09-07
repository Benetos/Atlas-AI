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
    @State private var expandedRouteIDs: Set<String> = []

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
                                Text("\(line.quantity.formatted())× \(line.title)")
                            }
                        }
                    }
                }
                targetSection(plan)
                Section {
                    checklist(for: plan.checklist)
                } header: {
                    HStack {
                        Text(feature.isFrozen ? "Saved gather list" : "Gather")
                        Spacer()
                        Text("\(checkedCount(plan.checklist)) of \(plan.checklist.count) checked")
                    }
                } footer: {
                    if !feature.isFrozen {
                        Text(plan.root.kind == .crafted
                             ? "Gather these ingredients, then follow the steps below. Changing a method updates this list."
                             : "Tap an item to mark it gathered. Changing a method updates this list.")
                    }
                }
                if !feature.isFrozen {
                    makeSection(plan)
                    routeSection(plan)
                }
                if !plan.cycles.isEmpty {
                    Section("Gather directly to finish this route") {
                        Text("A selected recipe needs an ingredient that leads back to itself. Gather the marked ingredient directly to continue.")
                            .foregroundStyle(.secondary)
                        ForEach(Array(plan.cycles.enumerated()), id: \.offset) { _, cycle in
                            Label(cycleSummary(cycle, plan: plan), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                                .font(.footnote)
                        }
                    }
                }
                if plan.truncated || !plan.notices.isEmpty {
                    Section("Plan notes") {
                        if plan.truncated {
                            Text("Some ingredients could not be expanded further. Gather the marked items directly, or choose another method.")
                        }
                        ForEach(Array(plan.notices.enumerated()), id: \.offset) { _, notice in
                            Text(notice)
                                .font(.footnote)
                        }
                    }
                }
                Section {
                    if !feature.isFrozen {
                        DisclosureGroup("Ingredient breakdown") {
                            PlanTreeRows(node: plan.root)
                        }
                    }
                    DisclosureGroup("Plan source") {
                        SourceBadge(
                            presentation: SourcePresentation(
                                kind: .calculated,
                                releaseLabel: plan.derivedEvidence.provenanceLabel
                            ),
                            expanded: true
                        )
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
            return "\(plan.quantity.formatted())× \(plan.targetTitle)"
        }
        return "Plan"
    }

    private func targetSection(_ plan: ComputedRecipePlan) -> some View {
        Section("Target") {
            Stepper(value: $feature.quantity, in: ConversationBounds.quantityRange) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.targetTitle)
                        .font(.headline)
                    Text("Quantity \(feature.quantity.formatted())")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .disabled(feature.isFrozen)
            .onChange(of: feature.quantity) {
                guard !feature.isFrozen else { return }
                Task { await reload() }
            }
            if feature.isFrozen {
                Text("Showing your saved route and gather list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(currentMethod(plan), systemImage: plan.root.kind == .crafted ? "hammer" : "shippingbox")
                        .font(.subheadline.weight(.medium))
                    Text(routeSummary(plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func makeSection(_ plan: ComputedRecipePlan) -> some View {
        let steps = craftingSteps(plan)
        if !steps.isEmpty {
            Section("Then make") {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(step.method) \(step.quantity.formatted())× \(step.title)")
                                .font(.subheadline.weight(.semibold))
                            Text("Use \(step.ingredientSummary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if step.surplus > 0 {
                                Text("Makes \(step.produced.formatted()) total; \(step.surplus.formatted()) left over.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(index + 1). \(step.method) \(step.quantity.formatted()) \(step.title). Use \(step.ingredientSummary).")
                }
            }
        }
    }

    @ViewBuilder
    private func routeSection(_ plan: ComputedRecipePlan) -> some View {
        let groups = routeGroups(plan)
        if !groups.isEmpty {
            Section {
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: routeExpansionBinding(group.nodeID)) {
                        routeOption(
                            title: "Gather directly",
                            detail: "Add \(group.quantity.formatted())× \(group.title) to the gather list.",
                            recipeID: RecipeAlternative.gatherID,
                            group: group,
                            plan: plan
                        )
                        ForEach(group.recipes) { recipe in
                            routeOption(
                                title: methodName(recipe.recipeKind),
                                detail: recipe.ingredientSummary.isEmpty ? "Ingredient details unavailable." : "Use \(recipe.ingredientSummary)",
                                outputSummary: "Makes \(recipe.outputAmount.formatted())× \(group.title) per batch",
                                recipeID: recipe.recipeID,
                                group: group,
                                plan: plan
                            )
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How to get \(group.title)")
                                .font(.subheadline)
                            Text("\(selectedMethod(group, plan: plan)) · \(group.quantity.formatted()) needed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                }
            } header: {
                Text("Change route")
            } footer: {
                Text("Choose one method for each item. Gather it directly, or make it from the ingredients shown.")
            }
        }
    }

    private func routeOption(
        title: String,
        detail: String,
        outputSummary: String? = nil,
        recipeID: String,
        group: NodeAlternatives,
        plan: ComputedRecipePlan
    ) -> some View {
        let selected = plan.selections[group.nodeID] == recipeID
        return Button {
            guard !selected else { return }
            selectAlternative(nodeID: group.nodeID, recipeID: recipeID)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if selected {
                            Text("Selected")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let outputSummary {
                        Text(outputSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Updates the ingredients and steps for this plan")
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
                    Text("\(line.quantity.formatted())× \(line.title)")
                        .strikethrough(feature.progress[line.id] == true)
                    if line.isCycle {
                        Text("Gather directly · recipe loops back here")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if line.isTruncated {
                        Text("Gather directly · further ingredients unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("\(line.quantity.formatted()) \(line.title)")
        .accessibilityValue(feature.progress[line.id] == true ? "Gathered" : "Not gathered")
        .accessibilityHint("Double tap to change gathered status")

        let link = AtlasOpenLink(
            destination: .entity(type: line.entityType, id: line.gameID),
            section: router.selectedSection
        ) {
            Image(systemName: "chevron.forward")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("About \(line.title)")

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

    private func routeExpansionBinding(_ nodeID: String) -> Binding<Bool> {
        Binding(
            get: { expandedRouteIDs.contains(nodeID) },
            set: { expanded in
                if expanded {
                    expandedRouteIDs.insert(nodeID)
                } else {
                    expandedRouteIDs.remove(nodeID)
                }
            }
        )
    }

    private func selectAlternative(nodeID: String, recipeID: String) {
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

    private func checkedCount(_ lines: [ChecklistLine]) -> Int {
        lines.filter { feature.progress[$0.id] == true }.count
    }

    private func routeSummary(_ plan: ComputedRecipePlan) -> String {
        let itemCount = plan.checklist.count
        let stepCount = craftingSteps(plan).count
        let items = "\(itemCount) \(itemCount == 1 ? "item" : "items") to gather"
        guard stepCount > 0 else { return items }
        return "\(items) · \(stepCount) \(stepCount == 1 ? "step" : "steps")"
    }

    private func routeGroups(_ plan: ComputedRecipePlan) -> [NodeAlternatives] {
        var groups: [NodeAlternatives] = []
        var seen: Set<String> = []
        func visit(_ node: PlanNode) {
            let nodeID = "entity:\(node.entityType):\(node.gameID)"
            if seen.insert(nodeID).inserted,
               let group = plan.alternatives.first(where: { $0.nodeID == nodeID }) {
                groups.append(group)
            }
            node.children.forEach(visit)
        }
        visit(plan.root)
        return groups
    }

    private func currentMethod(_ plan: ComputedRecipePlan) -> String {
        guard let group = plan.alternatives.first(where: { $0.nodeID == "entity:\(plan.targetType):\(plan.targetID)" }) else {
            return "Gather the target directly"
        }
        let selected = plan.selections[group.nodeID]
        if selected == RecipeAlternative.gatherID {
            return "Gather the target directly"
        }
        guard let recipe = group.recipes.first(where: { $0.recipeID == selected }) else {
            return "Gather the target directly"
        }
        return "\(methodName(recipe.recipeKind)) from the ingredients below"
    }

    private func selectedMethod(_ group: NodeAlternatives, plan: ComputedRecipePlan) -> String {
        let selected = plan.selections[group.nodeID]
        if selected == RecipeAlternative.gatherID { return "Selected: Gather" }
        guard let recipe = group.recipes.first(where: { $0.recipeID == selected }) else {
            return "Choose a method"
        }
        return "Selected: \(methodName(recipe.recipeKind))"
    }

    private func methodName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "crafting", "craft": "Craft"
        case "refining", "refine": "Refine"
        case "cooking", "cook": "Cook"
        default: "Make"
        }
    }

    private func craftingSteps(_ plan: ComputedRecipePlan) -> [PlanCraftingStep] {
        var steps: [PlanCraftingStep] = []
        func visit(_ node: PlanNode) {
            node.children.forEach(visit)
            guard node.kind == .crafted else { return }
            let stepID = "entity:\(node.entityType):\(node.gameID):\(node.selectedRecipeID ?? "")"
            let recipe = plan.alternatives
                .first { $0.nodeID == "entity:\(node.entityType):\(node.gameID)" }?
                .recipes.first { $0.recipeID == node.selectedRecipeID }
            let produced = (node.crafts ?? 1) * (node.outputPerCraft ?? node.quantity)
            let ingredients = node.children.map {
                PlanStepIngredient(id: "\($0.entityType):\($0.gameID)", title: $0.title, quantity: $0.quantity)
            }
            if let index = steps.firstIndex(where: { $0.id == stepID }) {
                steps[index].quantity += node.quantity
                steps[index].produced += produced
                for ingredient in ingredients {
                    if let ingredientIndex = steps[index].ingredients.firstIndex(where: { $0.id == ingredient.id }) {
                        steps[index].ingredients[ingredientIndex].quantity += ingredient.quantity
                    } else {
                        steps[index].ingredients.append(ingredient)
                    }
                }
            } else {
                steps.append(PlanCraftingStep(
                    id: stepID,
                    title: node.title,
                    quantity: node.quantity,
                    produced: produced,
                    method: methodName(recipe?.recipeKind ?? ""),
                    ingredients: ingredients
                ))
            }
        }
        visit(plan.root)
        return steps
    }

    private func cycleSummary(_ cycle: CycleNotice, plan: ComputedRecipePlan) -> String {
        var titles: [String: String] = [:]
        func visit(_ node: PlanNode) {
            if node.title != node.gameID {
                titles["entity:\(node.entityType):\(node.gameID)"] = node.title
            }
            node.children.forEach(visit)
        }
        visit(plan.root)
        for line in plan.checklist where line.title != line.gameID {
            titles["entity:\(line.entityType):\(line.gameID)"] = line.title
        }
        let names = cycle.path.enumerated().map { index, nodeID in
            if let pathTitles = cycle.pathTitles, pathTitles.indices.contains(index) {
                let title = pathTitles[index]
                if !title.isEmpty, title != nodeID, title != nodeID.split(separator: ":").last.map(String.init) {
                    return title
                }
            }
            return titles[nodeID] ?? "Unavailable ingredient"
        }
        return names.joined(separator: " → ")
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

private struct PlanStepIngredient {
    var id: String
    var title: String
    var quantity: Int
}

private struct PlanCraftingStep: Identifiable {
    var id: String
    var title: String
    var quantity: Int
    var produced: Int
    var method: String
    var ingredients: [PlanStepIngredient]

    var surplus: Int { max(0, produced - quantity) }
    var ingredientSummary: String {
        ingredients.map { "\($0.quantity.formatted())× \($0.title)" }.joined(separator: " + ")
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
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            Text(methodLabel).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        if let crafts = node.crafts {
            return "\(node.quantity.formatted())× \(node.title) (\(crafts.formatted()) batches)"
        }
        return "\(node.quantity.formatted())× \(node.title)"
    }

    private var methodLabel: String {
        switch node.kind {
        case .crafted: "Make from the ingredients below"
        case .leaf: "Gather directly"
        case .cycle: "Gather directly · recipe loops back here"
        case .truncated: "Gather directly · further ingredients unavailable"
        case .missingRecipe: "Gather directly · selected recipe unavailable"
        }
    }
}
