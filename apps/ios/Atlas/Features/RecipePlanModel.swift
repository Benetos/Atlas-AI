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

    var isFrozen: Bool { recomputeDiff?.hasChanges == true }

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
        if isFrozen, let savedRevision {
            quantity = savedRevision.quantity
            selections = savedRevision.selections
        }
        state = .loading
        lastError = nil
        do {
            let quantity = try Quantity.checked(self.quantity)
            var plan = try await RecipeGraphEngine().plan(
                targetType: type,
                targetID: id,
                quantity: quantity,
                packReleaseID: packIdentity?.sourceCommitSHA ?? "",
                source: catalog.asRecipeGraphSource(),
                selections: selections
            )
            try Task.checkCancellation()
            guard token == loadGeneration else { return }

            if let savedRevision {
                let packOrEngineStale = savedRevision.packReleaseID != plan.packReleaseID
                    || savedRevision.engineVersion != ComputedRecipePlan.engineVersion
                if packOrEngineStale,
                   savedRevision.quantity != plan.quantity
                    || savedRevision.selections != plan.selections {
                    plan = try await RecipeGraphEngine().plan(
                        targetType: type,
                        targetID: id,
                        quantity: savedRevision.quantity,
                        packReleaseID: packIdentity?.sourceCommitSHA ?? "",
                        source: catalog.asRecipeGraphSource(),
                        selections: savedRevision.selections
                    )
                    try Task.checkCancellation()
                    guard token == loadGeneration else { return }
                }
                let diff = RecipePlanRecomputeDiff.compare(saved: savedRevision, computed: plan)
                let sameInputs = savedRevision.quantity == plan.quantity
                    && savedRevision.selections == plan.selections
                if packOrEngineStale || (sameInputs && diff.hasChanges) {
                    self.quantity = savedRevision.quantity
                    self.selections = savedRevision.selections
                    progress = SavedRecipePlan.transferredProgress(
                        from: progress,
                        onto: savedRevision.checklist
                    )
                    recomputePreview = plan
                    recomputeDiff = diff
                    state = .loaded(.snapshot(from: savedRevision))
                    return
                }
                selections = plan.selections
                progress = SavedRecipePlan.transferredProgress(from: progress, onto: plan.checklist)
            } else {
                selections = plan.selections
            }
            recomputePreview = nil
            recomputeDiff = nil
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
        guard !isFrozen else { return }
        selections[nodeID] = recipeID
        await load(type: type, id: id, catalog: catalog, packIdentity: packIdentity, saved: saved)
    }

    func toggleProgress(
        lineID: String,
        clock: any Clock,
        saved: SavedStore
    ) async {
        progress[lineID] = !(progress[lineID] ?? false)
        guard let savedRevision else { return }
        do {
            var record = savedRevision
            record.progress = SavedRecipePlan.transferredProgress(
                from: progress,
                onto: record.checklist
            )
            record.updatedAt = clock.now()
            try await saved.upsertRecipePlan(record)
            self.savedRevision = record
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save(
        identifiers: any IdentifierSource,
        clock: any Clock,
        saved: SavedStore
    ) async {
        guard case .loaded(let plan) = state else { return }
        do {
            let now = clock.now()
            if let savedRevision, isFrozen {
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
            quantity = next.quantity
            didHydrateSavedPlan = true
            recomputePreview = nil
            recomputeDiff = nil
            state = .loaded(preview)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
