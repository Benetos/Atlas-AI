import Foundation
import SwiftUI

struct ContentDetailView: View {
    @Environment(AppModel.self) private var model
    var dataset: String
    var externalID: String
    var sourceOrdinal: Int

    @State private var feature = ContentDetailModel()

    var body: some View {
        LoadableStateView(
            state: feature.state,
            loadingTitle: "Loading record…",
            notFoundTitle: "Record not in this snapshot",
            notFoundSystemImage: "doc.text.magnifyingglass",
            failedTitle: "Could not load record",
            onRefresh: { Task { await load() } }
        ) { content in
            List {
                Section {
                    LabeledContent("Dataset", value: datasetTitle(content.record.dataset))
                    LabeledContent("Source ID", value: content.record.externalID)
                    SourceBadge(presentation: content.provenance, expanded: true)
                }

                if !content.fields.isEmpty {
                    Section("Details") {
                        ForEach(content.fields) { field in
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
                } footer: {
                    Text("This feature still uses Atlas’s lossless compatibility record. A dedicated screen can promote stable fields later.")
                }
            }
        }
        .navigationTitle(loadedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: routeKey) {
            await load()
        }
    }

    private var loadedTitle: String {
        if case .loaded(let content) = feature.state {
            return content.record.title
        }
        return "Record"
    }

    private var routeKey: String {
        "\(dataset):\(externalID):\(sourceOrdinal):\(model.generationID)"
    }

    @MainActor
    private func load() async {
        guard let catalog = model.catalog else {
            feature.state = .failed(CatalogError.unavailable.localizedDescription)
            return
        }
        await feature.load(
            dataset: dataset,
            id: externalID,
            sourceOrdinal: sourceOrdinal,
            catalog: catalog,
            packIdentity: model.packIdentity
        )
    }

    private func datasetTitle(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
