import SwiftUI

struct DestinationView: View {
    var destination: AppDestination
    var canDeleteReference: Bool = false

    var body: some View {
        switch destination {
        case .entity(let type, let id):
            EntityDetailView(
                entityType: type,
                gameID: id,
                canDeleteReference: canDeleteReference
            )
        case .recipe(let id):
            RecipeDetailView(recipeID: id, canDeleteReference: canDeleteReference)
        case .content(let dataset, let id, let sourceOrdinal):
            ContentDetailView(dataset: dataset, externalID: id, sourceOrdinal: sourceOrdinal)
        case .savedArtifact(let id):
            SavedArtifactDestinationView(artifactID: id)
        case .recipePlan(let type, let id, let quantity, let artifactID):
            RecipePlanView(
                targetType: type,
                targetID: id,
                quantity: quantity,
                artifactID: artifactID
            )
        case .unavailable(let unavailable):
            UnavailableDestinationView(destination: unavailable)
        }
    }
}

struct UnavailableDestinationView: View {
    var destination: UnavailableDestination

    @Environment(AppModel.self) private var model
    @Environment(AtlasRouter.self) private var router

    var body: some View {
        ContentUnavailableView {
            Label(destination.title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button("Back") {
                router.pop(in: router.selectedSection)
            }
            Button("Refresh") {
                Task {
                    await model.saved.bootstrap()
                    model.generationID += 1
                    if let key = destination.recordKey,
                       let item = model.saved.items.first(where: { $0.id == key })
                        ?? model.saved.recents.first(where: { $0.id == key })
                    {
                        router.select(item.destination, in: router.selectedSection)
                    }
                }
            }
            if destination.canDeleteReference, let key = destination.recordKey {
                Button("Delete Stale Reference", role: .destructive) {
                    Task {
                        await model.saved.removeItems(
                            at: IndexSet(
                                model.saved.items.enumerated().compactMap { index, item in
                                    item.id == key ? index : nil
                                }
                            )
                        )
                        router.pop(in: router.selectedSection)
                    }
                }
            }
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var systemImage: String {
        switch destination.reason {
        case .notFound, .deleted: "cube"
        case .capabilityUnavailable: "lock"
        case .packStale: "clock.arrow.circlepath"
        }
    }

    private var description: String {
        switch destination.reason {
        case .notFound:
            return "This record is not in the active snapshot."
        case .capabilityUnavailable:
            return "This destination is not available in the installed database."
        case .packStale:
            return "Refresh required. This destination belongs to a previous pack release."
        case .deleted:
            return "This saved reference is no longer available."
        }
    }
}

private struct SavedArtifactDestinationView: View {
    var artifactID: String

    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.generationID
        if let item = model.saved.items.first(where: { $0.id == artifactID })
            ?? model.saved.recents.first(where: { $0.id == artifactID })
        {
            DestinationView(destination: item.destination, canDeleteReference: true)
        } else if let plan = model.saved.recipePlan(id: artifactID) {
            RecipePlanView(
                targetType: plan.targetType,
                targetID: plan.targetID,
                quantity: plan.quantity,
                artifactID: plan.id
            )
        } else {
            UnavailableDestinationView(
                destination: UnavailableDestination(
                    title: "Saved item missing",
                    reason: .deleted,
                    recordKey: artifactID,
                    canDeleteReference: false
                )
            )
        }
    }
}
