import Foundation

@MainActor
@Observable
final class RecipePlanModel {
    var state: LoadState<ComputedRecipePlan> = .idle
    var quantity: Int
    var selections: [String: String]
    var progress: [String: Bool] = [:]
    var artifactID: String?
    var savedRevision: SavedRecipePlan?
    var recomputePreview: ComputedRecipePlan?
    var recomputeDiff: RecipePlanRecomputeDiff?
    var lastError: String?

    private var loadGeneration: UInt64 = 0
    private var didHydrateSavedPlan = false

    init(quantity: Int = 1, selections: [String: String] = [:], artifactID: String? = nil) {
        self.quantity = quantity
        self.selections = selections
        self.artifactID = artifactID
    }

    func load(
        type: String,
        id: String,
        catalog: any NMSCatalog,
        packIdentity: PackIdentity?,
        saved: SavedStore
    ) async {
        loadGeneration += 1
        let token = loadGeneration
        if let artifactID, let savedPlan = saved.recipePlan(id: artifactID) {
            savedRevision = savedPlan
            if !didHydrateSavedPlan {
                quantity = savedPlan.quantity
                selections = savedPlan.selections
                progress = savedPlan.progress
                didHydrateSavedPlan = true
            }
        }
        state = .loading
        lastError = nil
        recomputePreview = nil
        recomputeDiff = nil
        do {
            let quantity = try Quantity.checked(self.quantity)
            let plan = try await RecipeGraphEngine().plan(
                targetType: type,
                targetID: id,
                quantity: quantity,
                packReleaseID: packIdentity?.sourceCommitSHA ?? "",
                source: catalog.asRecipeGraphSource(),
                selections: selections
            )
            try Task.checkCancellation()
            guard token == loadGeneration else { return }
            selections = plan.selections
            if let savedRevision,
               savedRevision.quantity == plan.quantity,
               savedRevision.selections == plan.selections {
                let diff = RecipePlanRecomputeDiff.compare(saved: savedRevision, computed: plan)
                if diff.hasChanges {
                    recomputePreview = plan
                    recomputeDiff = diff
                    state = .loaded(planFromSavedSnapshot(savedRevision, live: plan))
                    return
                }
                progress = SavedRecipePlan.transferredProgress(from: progress, onto: plan.checklist)
            }
            state = .loaded(plan)
        } catch is CancellationError {
            return
        } catch let error as CatalogError {
            guard token == loadGeneration else { return }
            if case .notFound = error {
                state = .notFound
            } else {
                state = .failed(error.localizedDescription)
            }
        } catch {
            guard token == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func selectAlternative(
        nodeID: String,
        recipeID: String,
        type: String,
        id: String,
        catalog: any NMSCatalog,
        packIdentity: PackIdentity?,
        saved: SavedStore
    ) async {
        selections[nodeID] = recipeID
        await load(type: type, id: id, catalog: catalog, packIdentity: packIdentity, saved: saved)
    }

    func toggleProgress(lineID: String) {
        progress[lineID] = !(progress[lineID] ?? false)
    }

    func save(
        identifiers: any IdentifierSource,
        clock: any Clock,
        saved: SavedStore
    ) async {
        guard case .loaded(let plan) = state else { return }
        do {
            let now = clock.now()
            if let savedRevision, recomputeDiff?.hasChanges == true {
                var record = savedRevision
                record.progress = SavedRecipePlan.transferredProgress(from: progress, onto: record.checklist)
                record.updatedAt = now
                try await saved.upsertRecipePlan(record)
                self.savedRevision = record
                lastError = nil
                return
            }
            let isNew = artifactID == nil
            let id = artifactID ?? "recipePlan:\(identifiers.makeID())"
            var record = SavedRecipePlan.from(
                plan: plan,
                id: id,
                revision: isNew ? 1 : (savedRevision?.revision ?? 1),
                predecessorID: savedRevision?.predecessorID,
                progress: progress,
                now: isNew ? now : (savedRevision?.createdAt ?? now)
            )
            record.updatedAt = now
            try await saved.upsertRecipePlan(record)
            artifactID = id
            savedRevision = record
            didHydrateSavedPlan = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func confirmRecompute(
        identifiers: any IdentifierSource,
        clock: any Clock,
        saved: SavedStore
    ) async {
        guard let preview = recomputePreview, let previous = savedRevision else { return }
        do {
            let now = clock.now()
            let newID = "recipePlan:\(identifiers.makeID())"
            let next = SavedRecipePlan.from(
                plan: preview,
                id: newID,
                revision: previous.revision + 1,
                predecessorID: previous.id,
                progress: previous.progress,
                now: now
            )
            try await saved.upsertRecipePlan(next)
            artifactID = newID
            savedRevision = next
            progress = next.progress
            selections = next.selections
            didHydrateSavedPlan = true
            recomputePreview = nil
            recomputeDiff = nil
            state = .loaded(preview)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func planFromSavedSnapshot(_ saved: SavedRecipePlan, live: ComputedRecipePlan) -> ComputedRecipePlan {
        var snapshot = live
        snapshot.checklist = saved.checklist
        snapshot.notices = saved.notices + ["Pack or recipe data changed. Confirm to create a new revision."]
        snapshot.cycles = saved.cycles
        snapshot.truncated = saved.truncated
        snapshot.quantity = saved.quantity
        snapshot.selections = saved.selections
        return snapshot
    }
}
