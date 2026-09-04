import SwiftUI

struct SavedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let error = model.saved.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Plans") {
                if model.saved.recipePlans.isEmpty {
                    Text("Save a recipe plan from Atlas or an item detail screen.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.saved.recipePlans) { plan in
                        AtlasOpenLink(
                            destination: plan.destination,
                            section: .saved,
                            replacesPath: true
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.title)
                                Text("Revision \(plan.revision) · \(plan.checkedCount)/\(plan.checklist.count) gathered")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !plan.packReleaseID.isEmpty {
                                    SourceBadge(
                                        presentation: SourcePresentation(
                                            kind: .calculated,
                                            releaseLabel: String(plan.packReleaseID.prefix(12))
                                        ),
                                        expanded: true
                                    )
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        Task { await model.saved.removeRecipePlans(at: offsets) }
                    }
                }
            }
            Section("Bookmarks") {
                if model.saved.items.isEmpty {
                    Text("Bookmark items and recipes from their detail screens.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.saved.items) { item in
                        savedLink(item)
                    }
                    .onDelete { offsets in
                        Task { await model.saved.removeItems(at: offsets) }
                    }
                }
            }
            Section {
                if model.saved.recents.isEmpty {
                    Text("Items and recipes you open will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.saved.recents) { item in
                        savedLink(item)
                    }
                }
            } header: {
                HStack {
                    Text("Recents")
                    Spacer()
                    if !model.saved.recents.isEmpty {
                        Button("Clear") {
                            Task { await model.saved.clearRecents() }
                        }
                        .font(.caption)
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle("Saved")
    }

    @ViewBuilder
    private func savedLink(_ item: SavedItem) -> some View {
        AtlasOpenLink(
            destination: .savedArtifact(id: item.id),
            section: .saved,
            replacesPath: true
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                if let release = item.originatingPackReleaseID, !release.isEmpty {
                    SourceBadge(
                        presentation: SourcePresentation(
                            kind: .packed,
                            releaseLabel: String(release.prefix(12))
                        ),
                        expanded: true
                    )
                }
            }
        }
    }
}
